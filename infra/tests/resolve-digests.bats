#!/usr/bin/env bats
#
# Unit tests for infra/scripts/resolve-digests.sh.
#
# Three rules are worth a test here:
#
#   1. a build tag resolves to two immutable sha256 digests
#   2. an image whose org.opencontainers.image.revision label is not the commit
#      being deployed is refused - a moved tag must not become a deployment
#   3. a missing image, and a missing label, both fail closed
#
# `az` is a PATH stub (azval calls `command az`, which bypasses shell
# functions), it emits CRLF like the Windows az.cmd reached through WSL, and it
# answers `az account show --query '[a,b,c]' -o tsv` with one value PER LINE,
# which is what the real CLI does with a JMESPath array.
#
# The registry REST fallback is switched off for every test: it would reach out
# to a real host, and the CLI paths are the ones being described here.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  RESOLVE_SCRIPT="${REPO_ROOT}/infra/scripts/resolve-digests.sh"

  TEST_TMPDIR="${BATS_TEST_TMPDIR:-$(mktemp -d)}"
  STUB_BIN="${TEST_TMPDIR}/bin"
  mkdir -p "${STUB_BIN}"

  AZ_CALL_LOG="${TEST_TMPDIR}/az-calls.log"
  : >"${AZ_CALL_LOG}"
  export AZ_CALL_LOG

  write_az_stub
  PATH="${STUB_BIN}:${PATH}"
  export PATH

  export FAKE_TENANT_ID="a1571616-cb5c-4d81-93ab-83c3856d83f2"
  export FAKE_SUBSCRIPTION_ID="439cf6ec-8907-40ee-bae2-7efd9656cd09"
  export FAKE_ACR_NAME="crcostcopilot439cf6ec"

  # Keep the run hermetic: no token exchange, no HTTP.
  export RESOLVE_DIGESTS_USE_REGISTRY_API=0

  STAGING_SHA="ec36640"
  IMAGE_TAG="git-${STAGING_SHA}"
  OTHER_SHA="deadbee"

  # Which commit each image claims it was built from.
  export FAKE_FRONTEND_REVISION="${STAGING_SHA}"
  export FAKE_BACKEND_REVISION="${STAGING_SHA}"
  # Repository whose tag lookup finds nothing, e.g. cost-copilot-frontend.
  export FAKE_MISSING_REPOSITORY=""
  # 0 turns the revision label off, so the fail-closed path is exercised.
  export FAKE_LABEL_PRESENT=1

  FRONTEND_SHA256="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  BACKEND_SHA256="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
}

az_calls() {
  cat "${AZ_CALL_LOG}"
}

# resolve <extra args...> - run the script with stderr dropped, so $output is
# the JSON document and nothing else.
resolve_json() {
  run bash -c "bash '${RESOLVE_SCRIPT}' staging '${IMAGE_TAG}' '${STAGING_SHA}' 2>/dev/null"
}

write_az_stub() {
  cat >"${STUB_BIN}/az" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${AZ_CALL_LOG:-/dev/null}"

emit() { printf '%s\r\n' "$1"; }

arg_value() {
  local want="$1"
  shift
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "$want" ]; then
      printf '%s' "${2:-}"
      return 0
    fi
    shift
  done
  return 1
}

digest_for() {
  case "$1" in
    *frontend*) printf 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' ;;
    *) printf 'sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' ;;
  esac
}

revision_for() {
  case "$1" in
    *frontend*) printf '%s' "${FAKE_FRONTEND_REVISION:-}" ;;
    *) printf '%s' "${FAKE_BACKEND_REVISION:-}" ;;
  esac
}

case "$*" in
  version*)
    emit "2.84.0"
    ;;

  "account show"*)
    # One value PER LINE - a JMESPath array projected to tsv is not a tab row.
    emit "${FAKE_TENANT_ID}"
    emit "${FAKE_SUBSCRIPTION_ID}"
    emit "stub@example.test"
    ;;

  "acr show"*)
    emit "${FAKE_ACR_NAME}.azurecr.io"
    ;;

  # Longest prefix first: 'acr manifest show'* would swallow this one.
  "acr manifest show-metadata"*)
    reference="$(arg_value --name "$@")"
    repository="${reference%%:*}"
    if [ "$repository" = "${FAKE_MISSING_REPOSITORY:-}" ]; then
      printf 'ManifestUnknown: manifest tagged by "%s" is not found\n' "${reference#*:}" >&2
      exit 1
    fi
    emit "$(digest_for "$repository")"
    ;;

  "acr manifest show"*)
    reference="$(arg_value --name "$@")"
    repository="${reference%%@*}"
    if [ "${FAKE_LABEL_PRESENT:-1}" = "1" ]; then
      emit "{\"annotations\":{\"org.opencontainers.image.revision\":\"$(revision_for "$repository")\"}}"
    else
      emit '{"schemaVersion":2,"mediaType":"application/vnd.docker.distribution.manifest.v2+json"}'
    fi
    ;;

  "acr repository show"*)
    reference="$(arg_value --image "$@")"
    case "$reference" in
      *@sha256:*)
        # The attribute endpoint carries no image labels; this is the shape the
        # script has to cope with when the manifest did not answer either.
        emit '{"imageName":"stub","changeableAttributes":{"deleteEnabled":true}}'
        ;;
      *)
        repository="${reference%%:*}"
        if [ "$repository" = "${FAKE_MISSING_REPOSITORY:-}" ]; then
          printf 'ManifestUnknown\n' >&2
          exit 1
        fi
        emit "$(digest_for "$repository")"
        ;;
    esac
    ;;

  "acr login"*)
    printf 'the stub refuses to mint a registry token\n' >&2
    exit 1
    ;;

  *)
    printf 'unhandled az stub invocation: %s\n' "$*" >&2
    exit 1
    ;;
esac
STUB
  chmod +x "${STUB_BIN}/az"
}

# ---------------------------------------------------------------------------
# The happy path
# ---------------------------------------------------------------------------

@test "a build tag resolves to two sha256 digests" {
  resolve_json

  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.frontend.digest')" = "${FRONTEND_SHA256}" ]
  [ "$(echo "$output" | jq -r '.backend.digest')" = "${BACKEND_SHA256}" ]
  [ "$(echo "$output" | jq -r '.tag')" = "${IMAGE_TAG}" ]
}

@test "each digest is returned as a reference deploy.sh accepts" {
  resolve_json

  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.frontend.image | test("^crcostcopilot439cf6ec\\.azurecr\\.io/cost-copilot-frontend@sha256:[0-9a-f]{64}$")'
  echo "$output" | jq -e '.backend.image  | test("^crcostcopilot439cf6ec\\.azurecr\\.io/cost-copilot-backend@sha256:[0-9a-f]{64}$")'
}

@test "resolving is read-only: no Azure resource is changed" {
  resolve_json

  [ "$status" -eq 0 ]
  ! az_calls | grep -Eq ' (create|update|delete|set-mode|set) '
}

# ---------------------------------------------------------------------------
# The provenance gate
# ---------------------------------------------------------------------------

@test "an image built from another commit is rejected" {
  export FAKE_BACKEND_REVISION="${OTHER_SHA}"

  run bash "${RESOLVE_SCRIPT}" staging "${IMAGE_TAG}" "${STAGING_SHA}"

  [ "$status" -ne 0 ]
  echo "$output" | grep -q "built from commit '${OTHER_SHA}'"
  echo "$output" | grep -q "refusing to deploy an image built from a different commit"
}

@test "the frontend is checked too, not only the backend" {
  export FAKE_FRONTEND_REVISION="${OTHER_SHA}"

  run bash "${RESOLVE_SCRIPT}" staging "${IMAGE_TAG}" "${STAGING_SHA}"

  [ "$status" -ne 0 ]
  echo "$output" | grep -q "frontend:"
  echo "$output" | grep -q "refusing to deploy an image built from a different commit"
}

@test "an image with no revision label fails closed" {
  export FAKE_LABEL_PRESENT=0

  run bash "${RESOLVE_SCRIPT}" staging "${IMAGE_TAG}" "${STAGING_SHA}"

  [ "$status" -ne 0 ]
  echo "$output" | grep -q "carries no org.opencontainers.image.revision label"
  echo "$output" | grep -q "refusing to deploy an image with no provenance"
}

# ---------------------------------------------------------------------------
# Missing images
# ---------------------------------------------------------------------------

@test "a missing frontend image is a failure, not an empty digest" {
  export FAKE_MISSING_REPOSITORY="cost-copilot-frontend"

  run bash "${RESOLVE_SCRIPT}" staging "${IMAGE_TAG}" "${STAGING_SHA}"

  [ "$status" -ne 0 ]
  echo "$output" | grep -q "cannot resolve cost-copilot-frontend:${IMAGE_TAG} to a digest"
}

@test "a missing backend image is a failure too" {
  export FAKE_MISSING_REPOSITORY="cost-copilot-backend"

  run bash "${RESOLVE_SCRIPT}" staging "${IMAGE_TAG}" "${STAGING_SHA}"

  [ "$status" -ne 0 ]
  echo "$output" | grep -q "cannot resolve cost-copilot-backend:${IMAGE_TAG} to a digest"
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

@test "an unknown environment is rejected" {
  run bash "${RESOLVE_SCRIPT}" sandbox "${IMAGE_TAG}" "${STAGING_SHA}"

  [ "$status" -ne 0 ]
  echo "$output" | grep -q "unknown environment 'sandbox'"
}

@test "a run without an expected commit is rejected" {
  run bash "${RESOLVE_SCRIPT}" staging "${IMAGE_TAG}"

  [ "$status" -ne 0 ]
  echo "$output" | grep -q "no expected commit sha was given"
}

@test "a value that is not a commit sha is rejected" {
  run bash "${RESOLVE_SCRIPT}" staging "${IMAGE_TAG}" "refs/heads/staging"

  [ "$status" -ne 0 ]
  echo "$output" | grep -q "is not a git commit sha"
}
