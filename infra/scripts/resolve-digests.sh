#!/usr/bin/env bash
#
# resolve-digests.sh - turn one build tag into the two immutable image
# references deploy.sh accepts, and refuse to hand back an image that was not
# built from the commit being deployed.
#
#   bash infra/scripts/resolve-digests.sh staging git-<sha> <sha>
#
# stdout is a single JSON object; every log line goes to stderr:
#
#   {
#     "registry": "crcostcopilot439cf6ec",
#     "loginServer": "crcostcopilot439cf6ec.azurecr.io",
#     "tag": "git-ec36640",
#     "expectedRevision": "ec36640",
#     "frontend": { "repository": "...", "digest": "sha256:...", "image": "<loginServer>/<repo>@sha256:...", "revision": "ec36640" },
#     "backend":  { "repository": "...", "digest": "sha256:...", "image": "<loginServer>/<repo>@sha256:...", "revision": "ec36640" }
#   }
#
# Why the revision check exists
# -----------------------------
# A tag is a mutable pointer. Between the build that produced 'git-<sha>' and
# the deployment that reads it, that tag can be moved - by a re-run of an older
# commit, by a manual `docker push`, or by two pipelines racing on the same
# registry. Resolving the tag to a digest removes the race *after* this script
# runs, but not before it: the digest this script returns is still whatever the
# tag pointed at the moment it was read.
#
# So the digest alone is not enough. Each image also carries an
# org.opencontainers.image.revision label stamped at build time, and this script
# fails unless that label is exactly the commit the caller says it is deploying.
# An image built from a different commit is rejected even if its tag looks right.
#
# The label is read back from the registry, never trusted from the build step,
# and a missing label is a failure rather than a pass: an unlabelled image is
# indistinguishable from one somebody pushed by hand.
#
# This script is read-only. It calls no mutating Azure command and never uses
# az_do.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
. "${SCRIPT_DIR}/lib.sh"

INFRA_CONFIG_DIR="${INFRA_CONFIG_DIR:-${SCRIPT_DIR}/../config}"

# A manifest digest as every registry returns it: sha256 and lower case hex.
readonly DIGEST_PATTERN='^sha256:[0-9a-f]{64}$'
# Docker tag grammar, minus the leading '.' and '-' the spec also forbids.
readonly TAG_PATTERN='^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$'
# A git object name, abbreviated or full.
readonly REVISION_PATTERN='^[0-9a-f]{7,64}$'

TARGET_ENVIRONMENT=""
IMAGE_TAG=""
EXPECTED_REVISION=""
ACR_LOGIN_SERVER=""

FRONTEND_DIGEST=""
FRONTEND_REVISION=""
BACKEND_DIGEST=""
BACKEND_REVISION=""

# The registry REST fallback below is the only way to read an image *config*
# label when the Azure CLI does not surface one. Set this to 0 to keep a run
# hermetic (the tests do), at the cost of failing closed sooner.
USE_REGISTRY_API="${RESOLVE_DIGESTS_USE_REGISTRY_API:-1}"

trap cleanup_temp_files EXIT

# ---------------------------------------------------------------------------
# Arguments and configuration
# ---------------------------------------------------------------------------

usage() {
  printf 'usage: resolve-digests.sh <staging|production> <image-tag> <expected-commit-sha>\n' >&2
}

parse_arguments() {
  local candidate="${1:-}"
  case "$candidate" in
    staging | production) TARGET_ENVIRONMENT="$candidate" ;;
    '')
      usage
      die "no environment was given"
      ;;
    *)
      usage
      die "unknown environment '${candidate}'; expected 'staging' or 'production'"
      ;;
  esac

  IMAGE_TAG="${2:-}"
  if [ -z "$IMAGE_TAG" ]; then
    usage
    die "no image tag was given"
  fi
  if ! [[ "$IMAGE_TAG" =~ $TAG_PATTERN ]]; then
    die "'${IMAGE_TAG}' is not a valid image tag"
  fi

  EXPECTED_REVISION="$(lowercase "${3:-}")"
  if [ -z "$EXPECTED_REVISION" ]; then
    usage
    die "no expected commit sha was given; without it an image cannot be tied to a commit"
  fi
  if ! [[ "$EXPECTED_REVISION" =~ $REVISION_PATTERN ]]; then
    die "'${3:-}' is not a git commit sha"
  fi
}

load_environment_config() {
  load_config "${INFRA_CONFIG_DIR}/${TARGET_ENVIRONMENT}.env"
  load_config "${INFRA_CONFIG_DIR}/shared.env"

  require_env \
    AZURE_SUBSCRIPTION_ID AZURE_TENANT_ID APP_ENVIRONMENT \
    SHARED_RESOURCE_GROUP ACR_NAME \
    FRONTEND_IMAGE_REPOSITORY BACKEND_IMAGE_REPOSITORY IMAGE_REVISION_LABEL ||
    die "the ${TARGET_ENVIRONMENT} configuration is incomplete"

  if [ "$APP_ENVIRONMENT" != "$TARGET_ENVIRONMENT" ]; then
    die "APP_ENVIRONMENT is '${APP_ENVIRONMENT}' but the requested environment is '${TARGET_ENVIRONMENT}'"
  fi
}

resolve_login_server() {
  ACR_LOGIN_SERVER="$(azval acr show \
    --name "$ACR_NAME" --resource-group "$SHARED_RESOURCE_GROUP" \
    --query loginServer --output tsv 2>/dev/null || true)"
  [ -n "$ACR_LOGIN_SERVER" ] || ACR_LOGIN_SERVER="${ACR_NAME}.azurecr.io"
}

# ---------------------------------------------------------------------------
# Tag to digest
# ---------------------------------------------------------------------------

# resolve_digest <repository> - set RESOLVED_DIGEST to the manifest digest that
# IMAGE_TAG points at, or exit.
#
# The result comes back through a global rather than stdout: `die` inside a
# command substitution would only end the subshell, and a guard that can be
# swallowed by a subshell is not a guard.
#
# Two single-field projections rather than one multi-field one: `--query
# '[a,b]' -o tsv` prints one value per line, so a pair could not be told apart.
RESOLVED_DIGEST=""
resolve_digest() {
  local repository="${1:?resolve_digest requires a repository}"
  local digest

  RESOLVED_DIGEST=""

  digest="$(azval acr manifest show-metadata \
    --registry "$ACR_NAME" --name "${repository}:${IMAGE_TAG}" \
    --query digest --output tsv 2>/dev/null || true)"

  if [ -z "$digest" ]; then
    # Older CLI versions do not carry `acr manifest`; `acr repository show`
    # answers the same question through the other endpoint.
    digest="$(azval acr repository show \
      --name "$ACR_NAME" --image "${repository}:${IMAGE_TAG}" \
      --query digest --output tsv 2>/dev/null || true)"
  fi

  if [ -z "$digest" ]; then
    err "no manifest for ${repository}:${IMAGE_TAG} in registry ${ACR_NAME}"
    err "the build step either did not run, did not push, or pushed a different tag"
    die "cannot resolve ${repository}:${IMAGE_TAG} to a digest"
  fi

  if ! [[ "$digest" =~ $DIGEST_PATTERN ]]; then
    die "registry ${ACR_NAME} returned '${digest}' for ${repository}:${IMAGE_TAG}, which is not a sha256 digest"
  fi

  RESOLVED_DIGEST="$digest"
}

# ---------------------------------------------------------------------------
# Digest to commit
# ---------------------------------------------------------------------------

# revision_from_json <json> - first string value stored under the revision
# label anywhere in the document.
#
# The search is deliberately shape-agnostic. Depending on the registry, the
# CLI version and whether the image is an OCI or a Docker v2 manifest, the same
# label surfaces as a manifest annotation, as `.config.labels` or as the
# `.config.Labels` map of an image config blob. Descending recursively finds it
# in all of those without this script having to guess which one it is looking at.
revision_from_json() {
  local document="${1:-}"
  [ -n "$document" ] || return 0
  printf '%s' "$document" | jq -r --arg key "$IMAGE_REVISION_LABEL" '
    [ .. | objects | select(has($key)) | .[$key] | select(type == "string") ]
    | (.[0] // "")
  ' 2>/dev/null || printf ''
}

# revision_from_registry_api <repository> <digest>
#
# The Azure CLI exposes manifests but not the image *config* blob, which is
# where a LABEL actually lives on a Docker v2 image. This reads that blob
# directly from the registry's OAuth2-protected REST API.
#
# The refresh token and the bearer header are passed to curl through files, so
# neither appears in the process table of a shared runner, and neither is ever
# logged.
REGISTRY_TOKEN_FILE=""
REGISTRY_HEADER_FILE=""

revision_from_registry_api() {
  local repository="${1:?}" digest="${2:?}" rc=0 result=""

  command -v curl >/dev/null 2>&1 || {
    warn "curl is not installed; the registry REST fallback is unavailable"
    return 1
  }

  REGISTRY_TOKEN_FILE="$(mktemp)" || return 1
  REGISTRY_HEADER_FILE="$(mktemp)" || return 1
  chmod 600 "$REGISTRY_TOKEN_FILE" "$REGISTRY_HEADER_FILE"

  result="$(_registry_api_revision "$repository" "$digest")" || rc=$?

  # Deleted here rather than at exit: these two files hold registry credentials
  # and must not outlive the single lookup that needed them.
  rm -f -- "$REGISTRY_TOKEN_FILE" "$REGISTRY_HEADER_FILE"
  REGISTRY_TOKEN_FILE=""
  REGISTRY_HEADER_FILE=""

  printf '%s' "$result"
  return "$rc"
}

_registry_api_revision() {
  local repository="${1:?}" digest="${2:?}"
  local access manifest config_digest config

  if ! azval acr login --name "$ACR_NAME" --expose-token \
    --query accessToken --output tsv 2>/dev/null |
    tr -d '\r\n' >"$REGISTRY_TOKEN_FILE"; then
    warn "could not obtain a registry token for ${ACR_NAME}"
    return 1
  fi
  [ -s "$REGISTRY_TOKEN_FILE" ] || return 1

  access="$(curl --silent --show-error --fail --max-time 30 \
    --data-urlencode grant_type=refresh_token \
    --data-urlencode "service=${ACR_LOGIN_SERVER}" \
    --data-urlencode "scope=repository:${repository}:pull" \
    --data-urlencode "refresh_token@${REGISTRY_TOKEN_FILE}" \
    "https://${ACR_LOGIN_SERVER}/oauth2/token" 2>/dev/null |
    jq -r '.access_token // ""' 2>/dev/null || true)"
  [ -n "$access" ] || {
    warn "the registry token exchange for ${repository} did not return an access token"
    return 1
  }

  printf 'Authorization: Bearer %s\n' "$access" >"$REGISTRY_HEADER_FILE"

  manifest="$(curl --silent --show-error --fail --max-time 30 \
    --header "@${REGISTRY_HEADER_FILE}" \
    --header 'Accept: application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json' \
    "https://${ACR_LOGIN_SERVER}/v2/${repository}/manifests/${digest}" 2>/dev/null || true)"
  [ -n "$manifest" ] || return 1

  config_digest="$(printf '%s' "$manifest" | jq -r '.config.digest // ""' 2>/dev/null || true)"
  [ -n "$config_digest" ] || return 1

  config="$(curl --silent --show-error --fail --location --max-time 30 \
    --header "@${REGISTRY_HEADER_FILE}" \
    "https://${ACR_LOGIN_SERVER}/v2/${repository}/blobs/${config_digest}" 2>/dev/null || true)"
  [ -n "$config" ] || return 1

  revision_from_json "$config"
}

# read_revision <repository> <digest> - echo the revision label, or nothing.
read_revision() {
  local repository="${1:?}" digest="${2:?}"
  local document revision=""

  document="$(azval acr manifest show \
    --registry "$ACR_NAME" --name "${repository}@${digest}" \
    --output json 2>/dev/null || true)"
  revision="$(revision_from_json "$document")"

  if [ -z "$revision" ]; then
    document="$(azval acr repository show \
      --name "$ACR_NAME" --image "${repository}@${digest}" \
      --output json 2>/dev/null || true)"
    revision="$(revision_from_json "$document")"
  fi

  if [ -z "$revision" ] && [ "$USE_REGISTRY_API" = "1" ]; then
    revision="$(revision_from_registry_api "$repository" "$digest" || true)"
  fi

  printf '%s' "$(lowercase "$revision")"
}

# assert_built_from_expected_commit <label> <repository> <digest> - fatal unless
# the image carries the expected commit. Sets VERIFIED_REVISION on success.
VERIFIED_REVISION=""
assert_built_from_expected_commit() {
  local label="${1:?}" repository="${2:?}" digest="${3:?}"
  local revision

  VERIFIED_REVISION=""
  revision="$(read_revision "$repository" "$digest")"

  if [ -z "$revision" ]; then
    err "${label}: ${repository}@${digest} carries no ${IMAGE_REVISION_LABEL} label"
    err "tried: az acr manifest show, az acr repository show, and the registry blob API (enabled=${USE_REGISTRY_API})"
    err "an unlabelled image cannot be tied to a commit, so it is refused rather than trusted"
    err "fix the build: pass --build-arg IMAGE_REVISION=<sha> so the Dockerfile LABEL is stamped"
    die "refusing to deploy an image with no provenance"
  fi

  if [ "$revision" != "$EXPECTED_REVISION" ]; then
    err "${label}: ${repository}:${IMAGE_TAG} resolves to ${digest}"
    err "${label}: that image was built from commit '${revision}', but '${EXPECTED_REVISION}' is being deployed"
    err "the tag was moved, or an older build is still holding it"
    die "refusing to deploy an image built from a different commit"
  fi

  ok "${label}: ${repository}@${digest} was built from ${revision}"
  VERIFIED_REVISION="$revision"
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

emit_output() {
  jq -n \
    --arg registry "$ACR_NAME" \
    --arg loginServer "$ACR_LOGIN_SERVER" \
    --arg tag "$IMAGE_TAG" \
    --arg expectedRevision "$EXPECTED_REVISION" \
    --arg frontendRepository "$FRONTEND_IMAGE_REPOSITORY" \
    --arg frontendDigest "$FRONTEND_DIGEST" \
    --arg frontendRevision "$FRONTEND_REVISION" \
    --arg backendRepository "$BACKEND_IMAGE_REPOSITORY" \
    --arg backendDigest "$BACKEND_DIGEST" \
    --arg backendRevision "$BACKEND_REVISION" \
    '{
      registry: $registry,
      loginServer: $loginServer,
      tag: $tag,
      expectedRevision: $expectedRevision,
      frontend: {
        repository: $frontendRepository,
        digest: $frontendDigest,
        image: ($loginServer + "/" + $frontendRepository + "@" + $frontendDigest),
        revision: $frontendRevision
      },
      backend: {
        repository: $backendRepository,
        digest: $backendDigest,
        image: ($loginServer + "/" + $backendRepository + "@" + $backendDigest),
        revision: $backendRevision
      }
    }'
}

# ---------------------------------------------------------------------------

main() {
  parse_arguments "$@"
  log "resolving ${IMAGE_TAG} in the ${TARGET_ENVIRONMENT} registry (read-only)"
  require_cmd az jq || die "install the missing command-line tools and re-run"
  load_environment_config
  require_azure_context
  resolve_login_server

  # Both images are resolved and checked before either reference is printed, so
  # a caller can never act on half a result.
  resolve_digest "$FRONTEND_IMAGE_REPOSITORY"
  FRONTEND_DIGEST="$RESOLVED_DIGEST"
  resolve_digest "$BACKEND_IMAGE_REPOSITORY"
  BACKEND_DIGEST="$RESOLVED_DIGEST"

  assert_built_from_expected_commit frontend "$FRONTEND_IMAGE_REPOSITORY" "$FRONTEND_DIGEST"
  FRONTEND_REVISION="$VERIFIED_REVISION"
  assert_built_from_expected_commit backend "$BACKEND_IMAGE_REPOSITORY" "$BACKEND_DIGEST"
  BACKEND_REVISION="$VERIFIED_REVISION"

  ok "both images are pinned to ${EXPECTED_REVISION}"
  emit_output
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
