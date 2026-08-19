#!/usr/bin/env bash
#
# deploy.sh - roll a pinned pair of container images into one environment.
#
#   bash infra/scripts/deploy.sh staging \
#     crcostcopilot439cf6ec.azurecr.io/cost-copilot-frontend@sha256:<64 hex> \
#     crcostcopilot439cf6ec.azurecr.io/cost-copilot-backend@sha256:<64 hex>
#
# Digest-only by design. A mutable tag such as ':latest' or ':v1.2.3' means the
# bytes that were built, scanned and reviewed are not necessarily the bytes that
# run: the tag can be moved between the pipeline reading it and Container Apps
# pulling it. Every image reference is therefore required to be
# <registry>/<repository>@sha256:<64 lowercase hex> and anything else is
# rejected before a single Azure resource is touched.
#
# Roll-out order per app:
#
#   1. put the app in multiple-revision mode, so a new revision can exist
#      without taking traffic
#   2. update the image, which creates a new revision at 0% traffic
#   3. poll that revision until it is provisioned, running and healthy
#   4. only then shift 100% of the traffic to it
#
# If the new revision never becomes healthy the traffic is NOT shifted, the
# previous revision keeps serving, and the script exits non-zero.
#
# stdout is a single JSON object; every log line goes to stderr.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
. "${SCRIPT_DIR}/lib.sh"

INFRA_CONFIG_DIR="${INFRA_CONFIG_DIR:-${SCRIPT_DIR}/../config}"

# <anything>@sha256:<64 lowercase hex>. Anchored at both ends so a reference
# like 'repo:latest@sha256:...' or a trailing tag cannot slip past.
readonly DIGEST_PATTERN='^[A-Za-z0-9][A-Za-z0-9._/:-]*@sha256:[0-9a-f]{64}$'

TARGET_ENVIRONMENT=""
FRONTEND_IMAGE=""
BACKEND_IMAGE=""
FRONTEND_REVISION=""
BACKEND_REVISION=""

declare -a DEPLOYED_APPS=()

trap cleanup_temp_files EXIT

# ---------------------------------------------------------------------------
# Arguments and configuration
# ---------------------------------------------------------------------------

usage() {
  printf 'usage: deploy.sh <staging|production> <frontend-image@sha256:...> <backend-image@sha256:...>\n' >&2
}

# assert_pinned_by_digest <label> <reference>
assert_pinned_by_digest() {
  local label="${1:?assert_pinned_by_digest requires a label}"
  local reference="${2:-}"

  if [ -z "$reference" ]; then
    usage
    die "the ${label} image reference is missing"
  fi

  if [[ "$reference" =~ $DIGEST_PATTERN ]]; then
    return 0
  fi

  err "the ${label} image '${reference}' is not pinned to a digest"
  err "expected <registry>/<repository>@sha256:<64 lowercase hex>"
  case "$reference" in
    *@sha256:*) err "the digest is present but malformed; sha256 digests are exactly 64 lowercase hex characters" ;;
    *@*) err "only sha256 digests are accepted" ;;
    *:*) err "'${reference}' looks like a mutable tag; resolve it first, for example: az acr manifest list-metadata --name <repo> --registry <acr> --query \"[?tags[?@=='<tag>']].digest\"" ;;
    *) err "no digest was supplied at all" ;;
  esac
  die "refusing to deploy an image that is not pinned by digest"
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

  # Both references are validated before anything is deployed, so a bad backend
  # reference cannot leave the frontend half-rolled-out.
  assert_pinned_by_digest frontend "${2:-}"
  assert_pinned_by_digest backend "${3:-}"
  FRONTEND_IMAGE="$2"
  BACKEND_IMAGE="$3"

  ok "both images are pinned by digest"
}

load_environment_config() {
  load_config "${INFRA_CONFIG_DIR}/${TARGET_ENVIRONMENT}.env"
  load_config "${INFRA_CONFIG_DIR}/shared.env"

  require_env \
    AZURE_SUBSCRIPTION_ID AZURE_TENANT_ID APP_ENVIRONMENT \
    RESOURCE_GROUP FRONTEND_APP_NAME BACKEND_APP_NAME \
    DEPLOY_REVISION_TIMEOUT_SECONDS DEPLOY_REVISION_POLL_SECONDS ||
    die "the ${TARGET_ENVIRONMENT} configuration is incomplete"

  if [ "$APP_ENVIRONMENT" != "$TARGET_ENVIRONMENT" ]; then
    die "APP_ENVIRONMENT is '${APP_ENVIRONMENT}' but the requested environment is '${TARGET_ENVIRONMENT}'"
  fi
}

# ---------------------------------------------------------------------------
# Roll-out
# ---------------------------------------------------------------------------

# In single-revision mode Container Apps retires the old revision and moves all
# traffic the moment the image changes, which removes the very decision this
# script exists to make. Multiple-revision mode is therefore a precondition.
ensure_multiple_revision_mode() {
  local app_name="${1:?ensure_multiple_revision_mode requires an app name}"
  local mode

  mode="$(lowercase "$(azval containerapp show \
    --name "$app_name" --resource-group "$RESOURCE_GROUP" \
    --query 'properties.configuration.activeRevisionsMode' --output tsv 2>/dev/null || true)")"

  if [ "$mode" = "multiple" ]; then
    return 0
  fi

  log "switching ${app_name} to multiple-revision mode so traffic can be held back"
  az_do containerapp revision set-mode \
    --name "$app_name" --resource-group "$RESOURCE_GROUP" \
    --mode multiple --output none >/dev/null ||
    die "could not switch ${app_name} to multiple-revision mode"
}

# update_app_image <app name> <image> - sets DEPLOYED_REVISION to the revision
# the update produced.
DEPLOYED_REVISION=""
update_app_image() {
  local app_name="${1:?update_app_image requires an app name}"
  local image="${2:?update_app_image requires an image}"

  DEPLOYED_REVISION=""

  log "updating ${app_name} to ${image}"
  az_do containerapp update \
    --name "$app_name" --resource-group "$RESOURCE_GROUP" \
    --image "$image" --output none >/dev/null ||
    die "could not update ${app_name} to ${image}"

  if [ "${DRY_RUN:-0}" = "1" ]; then
    DEPLOYED_REVISION="dry-run"
    return 0
  fi

  # The revision name is read back rather than derived from a suffix: a re-run
  # with the same digest must not collide with an existing revision name.
  DEPLOYED_REVISION="$(azval containerapp show \
    --name "$app_name" --resource-group "$RESOURCE_GROUP" \
    --query 'properties.latestRevisionName' --output tsv 2>/dev/null || true)"
  [ -n "$DEPLOYED_REVISION" ] ||
    die "${app_name} reported no latest revision after the image update"

  ok "${app_name} produced revision ${DEPLOYED_REVISION}"
}

# wait_for_healthy_revision <app name> <revision name>
#
# Returns non-zero when the revision does not reach a healthy running state
# inside DEPLOY_REVISION_TIMEOUT_SECONDS, or when it fails outright.
wait_for_healthy_revision() {
  local app_name="${1:?wait_for_healthy_revision requires an app name}"
  local revision="${2:?wait_for_healthy_revision requires a revision name}"
  local deadline now provisioning running health

  if [ "${DRY_RUN:-0}" = "1" ]; then
    log "DRY_RUN: skipping the health wait for ${revision}"
    return 0
  fi

  deadline=$(($(date +%s) + DEPLOY_REVISION_TIMEOUT_SECONDS))

  while :; do
    # Each field is read on its own so the values never have to be pulled apart
    # from a multi-value tsv projection.
    provisioning="$(azval containerapp revision show \
      --name "$app_name" --resource-group "$RESOURCE_GROUP" --revision "$revision" \
      --query 'properties.provisioningState' --output tsv 2>/dev/null || true)"
    running="$(azval containerapp revision show \
      --name "$app_name" --resource-group "$RESOURCE_GROUP" --revision "$revision" \
      --query 'properties.runningState' --output tsv 2>/dev/null || true)"
    health="$(azval containerapp revision show \
      --name "$app_name" --resource-group "$RESOURCE_GROUP" --revision "$revision" \
      --query 'properties.healthState' --output tsv 2>/dev/null || true)"

    log "${app_name}/${revision}: provisioning=${provisioning:-unknown} running=${running:-unknown} health=${health:-unknown}"

    case "$provisioning" in
      Failed | Deprovisioning | Deprovisioned)
        err "revision ${revision} of ${app_name} reached provisioning state '${provisioning}'"
        return 1
        ;;
    esac
    case "$running" in
      Failed | Degraded | Stopped)
        err "revision ${revision} of ${app_name} reached running state '${running}'"
        return 1
        ;;
    esac
    if [ "$health" = "Unhealthy" ]; then
      err "revision ${revision} of ${app_name} reported an unhealthy state"
      return 1
    fi

    # A scale-to-zero app has no replica to be Healthy, so 'None' is accepted
    # alongside 'Healthy' as long as the revision is provisioned and running.
    if [ "$provisioning" = "Provisioned" ] &&
      { [ "$running" = "Running" ] || [ "$running" = "RunningAtMaxScale" ] || [ "$running" = "ScaledToZero" ]; } &&
      { [ "$health" = "Healthy" ] || [ "$health" = "None" ] || [ -z "$health" ]; }; then
      ok "revision ${revision} of ${app_name} is healthy"
      return 0
    fi

    now="$(date +%s)"
    if [ "$now" -ge "$deadline" ]; then
      err "revision ${revision} of ${app_name} did not become healthy within ${DEPLOY_REVISION_TIMEOUT_SECONDS}s"
      return 1
    fi
    sleep "$DEPLOY_REVISION_POLL_SECONDS"
  done
}

shift_traffic_to_revision() {
  local app_name="${1:?shift_traffic_to_revision requires an app name}"
  local revision="${2:?shift_traffic_to_revision requires a revision name}"

  log "shifting 100% of ${app_name} traffic to ${revision}"
  az_do containerapp ingress traffic set \
    --name "$app_name" --resource-group "$RESOURCE_GROUP" \
    --revision-weight "${revision}=100" --output none >/dev/null ||
    die "could not shift traffic on ${app_name} to ${revision}"
}

# deploy_app <app name> <image> - sets DEPLOYED_REVISION on success.
deploy_app() {
  local app_name="${1:?deploy_app requires an app name}"
  local image="${2:?deploy_app requires an image}"

  ensure_multiple_revision_mode "$app_name"
  update_app_image "$app_name" "$image"

  if ! wait_for_healthy_revision "$app_name" "$DEPLOYED_REVISION"; then
    err "leaving the previous revision of ${app_name} in place; no traffic was shifted"
    err "inspect it with: az containerapp revision show --name ${app_name} --resource-group ${RESOURCE_GROUP} --revision ${DEPLOYED_REVISION}"
    die "deployment of ${app_name} failed"
  fi

  shift_traffic_to_revision "$app_name" "$DEPLOYED_REVISION"
  DEPLOYED_APPS+=("$app_name")
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

emit_output() {
  jq -n \
    --arg environment "$APP_ENVIRONMENT" \
    --arg resourceGroup "$RESOURCE_GROUP" \
    --arg frontendApp "$FRONTEND_APP_NAME" \
    --arg frontendImage "$FRONTEND_IMAGE" \
    --arg frontendRevision "$FRONTEND_REVISION" \
    --arg backendApp "$BACKEND_APP_NAME" \
    --arg backendImage "$BACKEND_IMAGE" \
    --arg backendRevision "$BACKEND_REVISION" \
    '{
      environment: $environment,
      resourceGroup: $resourceGroup,
      pinnedByDigest: true,
      frontend: { appName: $frontendApp, image: $frontendImage, revision: $frontendRevision, trafficWeight: 100 },
      backend: { appName: $backendApp, image: $backendImage, revision: $backendRevision, trafficWeight: 100 }
    }'
}

# ---------------------------------------------------------------------------

main() {
  parse_arguments "$@"
  log "deploying to ${TARGET_ENVIRONMENT}"
  require_cmd az jq || die "install the missing command-line tools and re-run"
  load_environment_config
  require_azure_context
  ensure_az_extension containerapp

  # The backend goes first: the SPA calls it, so an API that is already serving
  # the new contract is less disruptive than the reverse.
  deploy_app "$BACKEND_APP_NAME" "$BACKEND_IMAGE"
  BACKEND_REVISION="$DEPLOYED_REVISION"

  deploy_app "$FRONTEND_APP_NAME" "$FRONTEND_IMAGE"
  FRONTEND_REVISION="$DEPLOYED_REVISION"

  ok "deployed ${#DEPLOYED_APPS[@]} container app(s) to ${TARGET_ENVIRONMENT}"
  emit_output
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
