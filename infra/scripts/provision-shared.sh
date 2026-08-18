#!/usr/bin/env bash
#
# provision-shared.sh - create the subscription-wide Azure Cost Copilot
# resources that both environments share.
#
#   * the shared resource group
#   * the container registry (admin user disabled; images are pulled with a
#     managed identity)
#   * the Azure Front Door Premium profile and one endpoint per environment
#
# Front Door origin groups, origins, routes and private-link approvals belong
# to Task 13; this script only lays down the profile and the endpoints.
#
# The script is idempotent: every resource is looked up first, created only
# when it is missing, left alone when it already matches, and updated when a
# property that this script owns has drifted.
#
# Usage:
#   bash infra/scripts/provision-shared.sh
#   DRY_RUN=1 bash infra/scripts/provision-shared.sh   # print, change nothing
#
# stdout is a single JSON object with the resulting names and resource IDs.
# Every log line goes to stderr.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
. "${SCRIPT_DIR}/lib.sh"

INFRA_CONFIG_DIR="${INFRA_CONFIG_DIR:-${SCRIPT_DIR}/../config}"

# Populated by the ensure_* functions and read by emit_output.
SHARED_RESOURCE_GROUP_ID=""
ACR_ID=""
ACR_LOGIN_SERVER=""
AFD_PROFILE_ID=""
AFD_STAGING_ENDPOINT_ID=""
AFD_STAGING_HOSTNAME=""
AFD_PRODUCTION_ENDPOINT_ID=""
AFD_PRODUCTION_HOSTNAME=""

declare -a SHARED_TAGS=()

trap cleanup_temp_files EXIT

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

load_shared_config() {
  load_config "${INFRA_CONFIG_DIR}/shared.env"
  # The shared resource names live in the per-environment files; preflight.sh
  # already fails when the two copies disagree, so either one will do.
  load_config "${INFRA_CONFIG_DIR}/staging.env"

  require_env \
    AZURE_SUBSCRIPTION_ID AZURE_TENANT_ID ACA_LOCATION \
    SHARED_RESOURCE_GROUP ACR_NAME ACR_SKU \
    AFD_PROFILE_NAME AFD_SKU \
    GITHUB_OWNER GITHUB_REPOSITORY WORKSHOP_NAME WORKSHOP_OWNER ||
    die "the shared configuration is incomplete"

  SHARED_TAGS=(
    "repository=${GITHUB_OWNER}/${GITHUB_REPOSITORY}"
    "environment=shared"
    "owner=${WORKSHOP_OWNER}"
    "workshop=${WORKSHOP_NAME}"
  )
}

# ---------------------------------------------------------------------------
# Resources
# ---------------------------------------------------------------------------

ensure_shared_resource_group() {
  local existing
  existing="$(azval group show --name "$SHARED_RESOURCE_GROUP" --output json 2>/dev/null || true)"

  if [ -n "$existing" ]; then
    SHARED_RESOURCE_GROUP_ID="$(printf '%s' "$existing" | jq -r '.id')"
    ok "resource group ${SHARED_RESOURCE_GROUP} already exists"
  else
    log "creating resource group ${SHARED_RESOURCE_GROUP} in ${ACA_LOCATION}"
    SHARED_RESOURCE_GROUP_ID="$(az_do group create \
      --name "$SHARED_RESOURCE_GROUP" \
      --location "$ACA_LOCATION" \
      --tags "${SHARED_TAGS[@]}" \
      --query id --output tsv)"
  fi

  ensure_tags "$SHARED_RESOURCE_GROUP_ID" "${SHARED_TAGS[@]}"
}

ensure_container_registry() {
  local existing sku admin_enabled
  existing="$(azval acr show \
    --name "$ACR_NAME" --resource-group "$SHARED_RESOURCE_GROUP" \
    --output json 2>/dev/null || true)"

  if [ -z "$existing" ]; then
    log "creating container registry ${ACR_NAME} (${ACR_SKU}, admin user disabled)"
    ACR_ID="$(az_do acr create \
      --name "$ACR_NAME" \
      --resource-group "$SHARED_RESOURCE_GROUP" \
      --location "$ACA_LOCATION" \
      --sku "$ACR_SKU" \
      --admin-enabled false \
      --query id --output tsv)"
    ACR_LOGIN_SERVER="${ACR_NAME}.azurecr.io"
  else
    ACR_ID="$(printf '%s' "$existing" | jq -r '.id')"
    ACR_LOGIN_SERVER="$(printf '%s' "$existing" | jq -r '.loginServer // ""')"
    sku="$(printf '%s' "$existing" | jq -r '.sku.name // ""')"
    admin_enabled="$(lowercase "$(printf '%s' "$existing" | jq -r '.adminUserEnabled // false')")"

    if [ "$sku" != "$ACR_SKU" ]; then
      log "container registry ${ACR_NAME} is '${sku}', expected '${ACR_SKU}'; updating the SKU"
      az_do acr update --name "$ACR_NAME" --resource-group "$SHARED_RESOURCE_GROUP" \
        --sku "$ACR_SKU" --output none >/dev/null
    fi

    # The admin user is a shared password credential. Deployments authenticate
    # with a managed identity instead, so it must stay off.
    if [ "$admin_enabled" != "false" ]; then
      warn "container registry ${ACR_NAME} has the admin user enabled; disabling it"
      az_do acr update --name "$ACR_NAME" --resource-group "$SHARED_RESOURCE_GROUP" \
        --admin-enabled false --output none >/dev/null
    fi

    ok "container registry ${ACR_NAME} already exists"
  fi

  [ -n "$ACR_LOGIN_SERVER" ] || ACR_LOGIN_SERVER="${ACR_NAME}.azurecr.io"
  ensure_tags "$ACR_ID" "${SHARED_TAGS[@]}"
}

ensure_frontdoor_profile() {
  local existing sku
  existing="$(azval afd profile show \
    --profile-name "$AFD_PROFILE_NAME" --resource-group "$SHARED_RESOURCE_GROUP" \
    --output json 2>/dev/null || true)"

  if [ -z "$existing" ]; then
    log "creating Front Door profile ${AFD_PROFILE_NAME} (${AFD_SKU})"
    # Front Door profiles are global; the command takes no --location.
    AFD_PROFILE_ID="$(az_do afd profile create \
      --profile-name "$AFD_PROFILE_NAME" \
      --resource-group "$SHARED_RESOURCE_GROUP" \
      --sku "$AFD_SKU" \
      --query id --output tsv)"
  else
    AFD_PROFILE_ID="$(printf '%s' "$existing" | jq -r '.id')"
    sku="$(printf '%s' "$existing" | jq -r '.sku.name // ""')"
    if [ "$sku" != "$AFD_SKU" ]; then
      # Standard can be upgraded to Premium in place; the reverse is not
      # allowed, so a failure here is reported and left for the operator.
      warn "Front Door profile ${AFD_PROFILE_NAME} is '${sku}', expected '${AFD_SKU}'; attempting an in-place SKU change"
      az_do afd profile update \
        --profile-name "$AFD_PROFILE_NAME" \
        --resource-group "$SHARED_RESOURCE_GROUP" \
        --sku "$AFD_SKU" --output none >/dev/null ||
        warn "the Front Door SKU change failed; private-link origins in Task 13 need ${AFD_SKU}"
    fi
    ok "Front Door profile ${AFD_PROFILE_NAME} already exists"
  fi

  ensure_tags "$AFD_PROFILE_ID" "${SHARED_TAGS[@]}"
}

# ensure_frontdoor_endpoint <endpoint name>
# Sets ENDPOINT_ID and ENDPOINT_HOSTNAME for the caller.
#
# The endpoints carry environment=shared like the rest of this script's
# resources: they live in the shared profile and resource group, and the
# workloads they will point at in Task 13 are tagged separately.
ENDPOINT_ID=""
ENDPOINT_HOSTNAME=""
ensure_frontdoor_endpoint() {
  local name="${1:?ensure_frontdoor_endpoint requires an endpoint name}"
  local existing state

  ENDPOINT_ID=""
  ENDPOINT_HOSTNAME=""

  existing="$(azval afd endpoint show \
    --endpoint-name "$name" \
    --profile-name "$AFD_PROFILE_NAME" \
    --resource-group "$SHARED_RESOURCE_GROUP" \
    --output json 2>/dev/null || true)"

  if [ -z "$existing" ]; then
    log "creating Front Door endpoint ${name} in profile ${AFD_PROFILE_NAME}"
    ENDPOINT_ID="$(az_do afd endpoint create \
      --endpoint-name "$name" \
      --profile-name "$AFD_PROFILE_NAME" \
      --resource-group "$SHARED_RESOURCE_GROUP" \
      --enabled-state Enabled \
      --query id --output tsv)"
    ENDPOINT_HOSTNAME="$(azval afd endpoint show \
      --endpoint-name "$name" \
      --profile-name "$AFD_PROFILE_NAME" \
      --resource-group "$SHARED_RESOURCE_GROUP" \
      --query hostName --output tsv 2>/dev/null || true)"
  else
    ENDPOINT_ID="$(printf '%s' "$existing" | jq -r '.id')"
    ENDPOINT_HOSTNAME="$(printf '%s' "$existing" | jq -r '.hostName // ""')"
    state="$(printf '%s' "$existing" | jq -r '.enabledState // ""')"
    if [ "$state" != "Enabled" ]; then
      log "Front Door endpoint ${name} is '${state}'; enabling it"
      az_do afd endpoint update \
        --endpoint-name "$name" \
        --profile-name "$AFD_PROFILE_NAME" \
        --resource-group "$SHARED_RESOURCE_GROUP" \
        --enabled-state Enabled --output none >/dev/null
    fi
    ok "Front Door endpoint ${name} already exists"
  fi

  ensure_tags "$ENDPOINT_ID" "${SHARED_TAGS[@]}"
}

ensure_frontdoor_endpoints() {
  local staging_endpoint production_endpoint

  staging_endpoint="$(config_value "${INFRA_CONFIG_DIR}/staging.env" AFD_ENDPOINT_NAME || true)"
  production_endpoint="$(config_value "${INFRA_CONFIG_DIR}/production.env" AFD_ENDPOINT_NAME || true)"
  [ -n "$staging_endpoint" ] || die "AFD_ENDPOINT_NAME is missing from staging.env"
  [ -n "$production_endpoint" ] || die "AFD_ENDPOINT_NAME is missing from production.env"

  ensure_frontdoor_endpoint "$staging_endpoint"
  AFD_STAGING_ENDPOINT_ID="$ENDPOINT_ID"
  AFD_STAGING_HOSTNAME="$ENDPOINT_HOSTNAME"

  ensure_frontdoor_endpoint "$production_endpoint"
  AFD_PRODUCTION_ENDPOINT_ID="$ENDPOINT_ID"
  AFD_PRODUCTION_HOSTNAME="$ENDPOINT_HOSTNAME"
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

emit_output() {
  # Built with jq so that a name containing a quote cannot produce broken JSON.
  jq -n \
    --arg subscriptionId "$AZURE_SUBSCRIPTION_ID" \
    --arg resourceGroup "$SHARED_RESOURCE_GROUP" \
    --arg resourceGroupId "$SHARED_RESOURCE_GROUP_ID" \
    --arg registryName "$ACR_NAME" \
    --arg registryId "$ACR_ID" \
    --arg registryLoginServer "$ACR_LOGIN_SERVER" \
    --arg frontDoorProfileName "$AFD_PROFILE_NAME" \
    --arg frontDoorProfileId "$AFD_PROFILE_ID" \
    --arg stagingEndpointId "$AFD_STAGING_ENDPOINT_ID" \
    --arg stagingHostname "$AFD_STAGING_HOSTNAME" \
    --arg productionEndpointId "$AFD_PRODUCTION_ENDPOINT_ID" \
    --arg productionHostname "$AFD_PRODUCTION_HOSTNAME" \
    '{
      subscriptionId: $subscriptionId,
      resourceGroup: { name: $resourceGroup, id: $resourceGroupId },
      containerRegistry: {
        name: $registryName,
        id: $registryId,
        loginServer: $registryLoginServer,
        adminUserEnabled: false
      },
      frontDoor: {
        profileName: $frontDoorProfileName,
        profileId: $frontDoorProfileId,
        endpoints: {
          staging: { id: $stagingEndpointId, hostname: $stagingHostname },
          production: { id: $productionEndpointId, hostname: $productionHostname }
        }
      }
    }'
}

# ---------------------------------------------------------------------------

main() {
  log "provisioning the shared Azure Cost Copilot resources"
  require_cmd az jq || die "install the missing command-line tools and re-run"
  load_shared_config
  require_azure_context

  ensure_shared_resource_group
  ensure_container_registry
  ensure_frontdoor_profile
  ensure_frontdoor_endpoints

  ok "shared resources are provisioned"
  emit_output
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
