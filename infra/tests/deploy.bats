#!/usr/bin/env bats
#
# Unit tests for infra/scripts/deploy.sh.
#
# The point of these tests is the two rules that keep a deployment honest:
#
#   1. only an image pinned to a sha256 digest is ever deployed
#   2. traffic only moves after the new revision is healthy
#
# `az` is a PATH stub (azval and az_do call `command az`, which bypasses shell
# functions), it emits CRLF like the Windows az.cmd reached through WSL, and it
# answers `az account show --query '[a,b,c]' -o tsv` with one value PER LINE,
# which is what the real CLI does with a JMESPath array.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPTS_DIR="${REPO_ROOT}/infra/scripts"
  DEPLOY_SCRIPT="${SCRIPTS_DIR}/deploy.sh"

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

  # healthy | failed | stuck - how the new revision behaves.
  export FAKE_REVISION_STATE="healthy"
  # single | multiple - the revision mode the apps start in.
  export FAKE_REVISION_MODE="multiple"

  # Keep the poll loop from actually waiting.
  export DEPLOY_REVISION_POLL_SECONDS=0
  export DEPLOY_REVISION_TIMEOUT_SECONDS=0

  DIGEST="sha256:1111111111111111111111111111111111111111111111111111111111111111"
  FRONTEND_DIGEST="crcostcopilot439cf6ec.azurecr.io/cost-copilot-frontend@${DIGEST}"
  BACKEND_DIGEST="crcostcopilot439cf6ec.azurecr.io/cost-copilot-backend@${DIGEST}"
}

az_calls() {
  cat "${AZ_CALL_LOG}"
}

write_az_stub() {
  cat >"${STUB_BIN}/az" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${AZ_CALL_LOG:-/dev/null}"

emit() { printf '%s\r\n' "$1"; }

sub="${FAKE_SUBSCRIPTION_ID}"
base="/subscriptions/${sub}/resourceGroups/rg-cost-copilot-staging"

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

  "extension show"*)
    emit "$(arg_value --name "$@")"
    ;;
  "extension add"*)
    emit '{}'
    ;;

  "containerapp show"*)
    app_name="$(arg_value --name "$@")"
    case "$*" in
      *activeRevisionsMode*) emit "${FAKE_REVISION_MODE:-multiple}" ;;
      *latestRevisionName*) emit "${app_name}--rev0002" ;;
      *) emit "${base}/providers/Microsoft.App/containerApps/${app_name}" ;;
    esac
    ;;
  "containerapp revision set-mode"*)
    emit '{}'
    ;;
  "containerapp update"*)
    emit '{}'
    ;;
  "containerapp revision show"*)
    case "${FAKE_REVISION_STATE:-healthy}" in
      failed)
        case "$*" in
          *provisioningState*) emit "Failed" ;;
          *runningState*) emit "Failed" ;;
          *) emit "Unhealthy" ;;
        esac
        ;;
      stuck)
        # Never leaves the provisioning state, so only the timeout ends it.
        case "$*" in
          *provisioningState*) emit "Provisioning" ;;
          *runningState*) emit "Processing" ;;
          *) emit "None" ;;
        esac
        ;;
      *)
        case "$*" in
          *provisioningState*) emit "Provisioned" ;;
          *runningState*) emit "Running" ;;
          *) emit "Healthy" ;;
        esac
        ;;
    esac
    ;;
  "containerapp ingress traffic set"*)
    emit '{}'
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
# The digest gate
# ---------------------------------------------------------------------------

@test "a mutable tag is rejected and nothing is deployed" {
  run bash "${DEPLOY_SCRIPT}" staging \
    "crcostcopilot439cf6ec.azurecr.io/cost-copilot-frontend:latest" \
    "${BACKEND_DIGEST}"

  [ "$status" -ne 0 ]
  echo "$output" | grep -q "is not pinned to a digest"
  echo "$output" | grep -q "looks like a mutable tag"
  ! az_calls | grep -q "containerapp update"
  ! az_calls | grep -q "containerapp ingress traffic set"
}

@test "a semantic version tag is rejected too" {
  run bash "${DEPLOY_SCRIPT}" staging \
    "${FRONTEND_DIGEST}" \
    "crcostcopilot439cf6ec.azurecr.io/cost-copilot-backend:v1.2.3"

  [ "$status" -ne 0 ]
  echo "$output" | grep -q "is not pinned to a digest"
  ! az_calls | grep -q "containerapp update"
}

@test "a digest that is not sha256 is rejected" {
  run bash "${DEPLOY_SCRIPT}" staging \
    "crcostcopilot439cf6ec.azurecr.io/cost-copilot-frontend@sha512:1111111111111111111111111111111111111111111111111111111111111111" \
    "${BACKEND_DIGEST}"

  [ "$status" -ne 0 ]
  echo "$output" | grep -q "only sha256 digests are accepted"
  ! az_calls | grep -q "containerapp update"
}

@test "a truncated sha256 digest is rejected" {
  run bash "${DEPLOY_SCRIPT}" staging \
    "crcostcopilot439cf6ec.azurecr.io/cost-copilot-frontend@sha256:1111" \
    "${BACKEND_DIGEST}"

  [ "$status" -ne 0 ]
  echo "$output" | grep -q "the digest is present but malformed"
  ! az_calls | grep -q "containerapp update"
}

@test "an upper case digest is rejected, because registries return lower case hex" {
  run bash "${DEPLOY_SCRIPT}" staging \
    "crcostcopilot439cf6ec.azurecr.io/cost-copilot-frontend@sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" \
    "${BACKEND_DIGEST}"

  [ "$status" -ne 0 ]
  ! az_calls | grep -q "containerapp update"
}

@test "a bad backend reference stops the frontend from being half deployed" {
  run bash "${DEPLOY_SCRIPT}" staging "${FRONTEND_DIGEST}" "backend:latest"

  [ "$status" -ne 0 ]
  ! az_calls | grep -q "containerapp update"
}

@test "a missing image argument is rejected" {
  run bash "${DEPLOY_SCRIPT}" staging "${FRONTEND_DIGEST}"

  [ "$status" -ne 0 ]
  echo "$output" | grep -q "the backend image reference is missing"
  ! az_calls | grep -q "containerapp update"
}

@test "two digest-pinned images are accepted and deployed" {
  run bash "${DEPLOY_SCRIPT}" staging "${FRONTEND_DIGEST}" "${BACKEND_DIGEST}"

  [ "$status" -eq 0 ]
  az_calls | grep -q "containerapp update --name ca-cc-backend-staging .* --image ${BACKEND_DIGEST}"
  az_calls | grep -q "containerapp update --name ca-cc-frontend-staging .* --image ${FRONTEND_DIGEST}"
}

# ---------------------------------------------------------------------------
# Health before traffic
# ---------------------------------------------------------------------------

@test "traffic moves to the new revision only after it is healthy" {
  run bash "${DEPLOY_SCRIPT}" staging "${FRONTEND_DIGEST}" "${BACKEND_DIGEST}"

  [ "$status" -eq 0 ]
  az_calls | grep -q "containerapp ingress traffic set --name ca-cc-backend-staging .* --revision-weight ca-cc-backend-staging--rev0002=100"
  az_calls | grep -q "containerapp ingress traffic set --name ca-cc-frontend-staging .* --revision-weight ca-cc-frontend-staging--rev0002=100"
}

@test "a failed revision never receives traffic and the deploy exits non-zero" {
  export FAKE_REVISION_STATE="failed"

  run bash "${DEPLOY_SCRIPT}" staging "${FRONTEND_DIGEST}" "${BACKEND_DIGEST}"

  [ "$status" -ne 0 ]
  az_calls | grep -q "containerapp update --name ca-cc-backend-staging"
  ! az_calls | grep -q "containerapp ingress traffic set"
  echo "$output" | grep -q "no traffic was shifted"
}

@test "a revision that never finishes provisioning times out without shifting traffic" {
  export FAKE_REVISION_STATE="stuck"

  run bash "${DEPLOY_SCRIPT}" staging "${FRONTEND_DIGEST}" "${BACKEND_DIGEST}"

  [ "$status" -ne 0 ]
  ! az_calls | grep -q "containerapp ingress traffic set"
  echo "$output" | grep -q "did not become healthy within"
}

@test "the frontend is left untouched when the backend roll-out fails" {
  export FAKE_REVISION_STATE="failed"

  run bash "${DEPLOY_SCRIPT}" staging "${FRONTEND_DIGEST}" "${BACKEND_DIGEST}"

  [ "$status" -ne 0 ]
  ! az_calls | grep -q "containerapp update --name ca-cc-frontend-staging"
}

@test "a single-revision app is switched to multiple revisions so traffic can be held" {
  export FAKE_REVISION_MODE="single"

  run bash "${DEPLOY_SCRIPT}" staging "${FRONTEND_DIGEST}" "${BACKEND_DIGEST}"

  [ "$status" -eq 0 ]
  az_calls | grep -q "containerapp revision set-mode --name ca-cc-backend-staging .* --mode multiple"
}

@test "an app already in multiple-revision mode is not switched again" {
  run bash "${DEPLOY_SCRIPT}" staging "${FRONTEND_DIGEST}" "${BACKEND_DIGEST}"

  [ "$status" -eq 0 ]
  ! az_calls | grep -q "containerapp revision set-mode"
}

@test "the deployment result is emitted as JSON on stdout" {
  bash "${DEPLOY_SCRIPT}" staging "${FRONTEND_DIGEST}" "${BACKEND_DIGEST}" \
    >"${TEST_TMPDIR}/deploy.json" 2>"${TEST_TMPDIR}/deploy.log"

  jq -e '.pinnedByDigest == true' <"${TEST_TMPDIR}/deploy.json"
  jq -e '.backend.trafficWeight == 100' <"${TEST_TMPDIR}/deploy.json"
  jq -e '.frontend.revision == "ca-cc-frontend-staging--rev0002"' <"${TEST_TMPDIR}/deploy.json"
}

@test "an unknown environment is rejected before any Azure call" {
  run bash "${DEPLOY_SCRIPT}" nonsense "${FRONTEND_DIGEST}" "${BACKEND_DIGEST}"

  [ "$status" -ne 0 ]
  echo "$output" | grep -q "unknown environment"
  [ ! -s "${AZ_CALL_LOG}" ]
}
