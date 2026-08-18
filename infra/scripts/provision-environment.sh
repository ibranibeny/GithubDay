#!/usr/bin/env bash
#
# provision-environment.sh - create the isolated Azure resources for one
# Azure Cost Copilot environment.
#
#   bash infra/scripts/provision-environment.sh staging
#   bash infra/scripts/provision-environment.sh production
#   DRY_RUN=1 bash infra/scripts/provision-environment.sh staging
#
# Creates, in this order, so that every dependency exists before it is used:
#
#   resource group -> virtual network (/23 Container Apps infrastructure subnet
#   plus /24 private endpoint subnet) -> Log Analytics workspace ->
#   workspace-based Application Insights -> internal workload-profiles Container
#   Apps environment -> backend and frontend runtime identities -> role
#   assignments -> container apps -> diagnostic settings.
#
# Least privilege is a hard rule here: only the BACKEND identity is granted
# Cost Management Reader and Cognitive Services OpenAI User. The frontend
# identity receives AcrPull and nothing else - it serves static files and must
# never be able to read cost data or call the model.
#
# The container apps are created from a public placeholder image because the
# real images do not exist until the deployment workflows run. An app that
# already exists is never re-imaged here.
#
# stdout is a single JSON object with the resulting names and resource IDs.
# Every log line goes to stderr.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
. "${SCRIPT_DIR}/lib.sh"

INFRA_CONFIG_DIR="${INFRA_CONFIG_DIR:-${SCRIPT_DIR}/../config}"

DIAGNOSTIC_SETTING_NAME="${DIAGNOSTIC_SETTING_NAME:-cost-copilot-diagnostics}"

# Populated by the ensure_* functions and read by emit_output.
TARGET_ENVIRONMENT=""
RESOURCE_GROUP_ID=""
VNET_ID=""
ACA_SUBNET_ID=""
PRIVATE_ENDPOINT_SUBNET_ID=""
LOG_ANALYTICS_ID=""
APP_INSIGHTS_ID=""
ACA_ENVIRONMENT_ID=""
ACR_ID=""
ACR_LOGIN_SERVER=""
FOUNDRY_ACCOUNT_ID=""
BACKEND_IDENTITY_ID=""
BACKEND_IDENTITY_PRINCIPAL_ID=""
BACKEND_IDENTITY_CLIENT_ID=""
FRONTEND_IDENTITY_ID=""
FRONTEND_IDENTITY_PRINCIPAL_ID=""
FRONTEND_IDENTITY_CLIENT_ID=""
BACKEND_APP_ID=""
FRONTEND_APP_ID=""

declare -a ENVIRONMENT_TAGS=()

trap cleanup_temp_files EXIT

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

parse_environment_argument() {
  local candidate="${1:-}"
  case "$candidate" in
    staging | production)
      TARGET_ENVIRONMENT="$candidate"
      ;;
    '')
      die "usage: provision-environment.sh <staging|production>"
      ;;
    *)
      die "unknown environment '${candidate}'; expected 'staging' or 'production'"
      ;;
  esac
}

load_environment_config() {
  # The environment file is loaded first so its values win; load_config never
  # overwrites something that is already set, and the process environment wins
  # over both files.
  load_config "${INFRA_CONFIG_DIR}/${TARGET_ENVIRONMENT}.env"
  load_config "${INFRA_CONFIG_DIR}/shared.env"

  require_env \
    AZURE_SUBSCRIPTION_ID AZURE_TENANT_ID ACA_LOCATION APP_ENVIRONMENT \
    RESOURCE_GROUP SHARED_RESOURCE_GROUP ACR_NAME \
    VNET_NAME VNET_ADDRESS_PREFIX \
    ACA_SUBNET_NAME ACA_SUBNET_PREFIX \
    PRIVATE_ENDPOINT_SUBNET_NAME PRIVATE_ENDPOINT_SUBNET_PREFIX \
    LOG_ANALYTICS_NAME LOG_ANALYTICS_RETENTION_DAYS APP_INSIGHTS_NAME \
    ACA_ENVIRONMENT_NAME ACA_WORKLOAD_PROFILE_NAME \
    BACKEND_IDENTITY_NAME FRONTEND_IDENTITY_NAME \
    BACKEND_APP_NAME FRONTEND_APP_NAME \
    BOOTSTRAP_IMAGE BOOTSTRAP_TARGET_PORT ACA_MIN_REPLICAS ACA_MAX_REPLICAS \
    FOUNDRY_RESOURCE_GROUP FOUNDRY_ACCOUNT_NAME \
    GITHUB_OWNER GITHUB_REPOSITORY WORKSHOP_NAME WORKSHOP_OWNER ||
    die "the ${TARGET_ENVIRONMENT} configuration is incomplete"

  if [ "$APP_ENVIRONMENT" != "$TARGET_ENVIRONMENT" ]; then
    die "APP_ENVIRONMENT is '${APP_ENVIRONMENT}' but the requested environment is '${TARGET_ENVIRONMENT}'"
  fi

  ENVIRONMENT_TAGS=(
    "repository=${GITHUB_OWNER}/${GITHUB_REPOSITORY}"
    "environment=${APP_ENVIRONMENT}"
    "owner=${WORKSHOP_OWNER}"
    "workshop=${WORKSHOP_NAME}"
  )
}

# ---------------------------------------------------------------------------
# Shared resources this environment depends on
# ---------------------------------------------------------------------------

resolve_shared_dependencies() {
  local registry
  registry="$(azval acr show \
    --name "$ACR_NAME" --resource-group "$SHARED_RESOURCE_GROUP" \
    --output json 2>/dev/null || true)"
  [ -n "$registry" ] ||
    die "container registry ${ACR_NAME} was not found in ${SHARED_RESOURCE_GROUP}; run provision-shared.sh first"
  ACR_ID="$(printf '%s' "$registry" | jq -r '.id')"
  ACR_LOGIN_SERVER="$(printf '%s' "$registry" | jq -r '.loginServer // ""')"
  [ -n "$ACR_LOGIN_SERVER" ] || ACR_LOGIN_SERVER="${ACR_NAME}.azurecr.io"

  FOUNDRY_ACCOUNT_ID="$(azval cognitiveservices account show \
    --name "$FOUNDRY_ACCOUNT_NAME" --resource-group "$FOUNDRY_RESOURCE_GROUP" \
    --query id --output tsv 2>/dev/null || true)"
  [ -n "$FOUNDRY_ACCOUNT_ID" ] ||
    die "Foundry account ${FOUNDRY_RESOURCE_GROUP}/${FOUNDRY_ACCOUNT_NAME} was not found; the backend identity cannot be scoped to it"
}

# ---------------------------------------------------------------------------
# Resources
# ---------------------------------------------------------------------------

ensure_environment_resource_group() {
  local existing
  existing="$(azval group show --name "$RESOURCE_GROUP" --output json 2>/dev/null || true)"

  if [ -n "$existing" ]; then
    RESOURCE_GROUP_ID="$(printf '%s' "$existing" | jq -r '.id')"
    ok "resource group ${RESOURCE_GROUP} already exists"
  else
    log "creating resource group ${RESOURCE_GROUP} in ${ACA_LOCATION}"
    RESOURCE_GROUP_ID="$(az_do group create \
      --name "$RESOURCE_GROUP" \
      --location "$ACA_LOCATION" \
      --tags "${ENVIRONMENT_TAGS[@]}" \
      --query id --output tsv)"
  fi

  ensure_tags "$RESOURCE_GROUP_ID" "${ENVIRONMENT_TAGS[@]}"
}

ensure_virtual_network() {
  local existing prefixes
  existing="$(azval network vnet show \
    --name "$VNET_NAME" --resource-group "$RESOURCE_GROUP" \
    --output json 2>/dev/null || true)"

  if [ -z "$existing" ]; then
    log "creating virtual network ${VNET_NAME} (${VNET_ADDRESS_PREFIX})"
    VNET_ID="$(az_do network vnet create \
      --name "$VNET_NAME" \
      --resource-group "$RESOURCE_GROUP" \
      --location "$ACA_LOCATION" \
      --address-prefixes "$VNET_ADDRESS_PREFIX" \
      --query 'newVNet.id' --output tsv)"
  else
    VNET_ID="$(printf '%s' "$existing" | jq -r '.id')"
    prefixes="$(printf '%s' "$existing" | jq -r '.addressSpace.addressPrefixes | join(",")')"
    # Re-addressing a virtual network that already carries a Container Apps
    # environment is destructive, so this is reported instead of "fixed".
    case ",${prefixes}," in
      *",${VNET_ADDRESS_PREFIX},"*) : ;;
      *) die "virtual network ${VNET_NAME} has address space '${prefixes}' but the configuration expects '${VNET_ADDRESS_PREFIX}'; resolve this by hand" ;;
    esac
    ok "virtual network ${VNET_NAME} already exists"
  fi

  ensure_tags "$VNET_ID" "${ENVIRONMENT_TAGS[@]}"
}

ensure_aca_subnet() {
  local existing prefix delegation
  existing="$(azval network vnet subnet show \
    --name "$ACA_SUBNET_NAME" --vnet-name "$VNET_NAME" --resource-group "$RESOURCE_GROUP" \
    --output json 2>/dev/null || true)"

  if [ -z "$existing" ]; then
    log "creating Container Apps infrastructure subnet ${ACA_SUBNET_NAME} (${ACA_SUBNET_PREFIX})"
    # A workload-profiles environment requires a delegated /23 or larger.
    ACA_SUBNET_ID="$(az_do network vnet subnet create \
      --name "$ACA_SUBNET_NAME" \
      --vnet-name "$VNET_NAME" \
      --resource-group "$RESOURCE_GROUP" \
      --address-prefixes "$ACA_SUBNET_PREFIX" \
      --delegations Microsoft.App/environments \
      --query id --output tsv)"
    return 0
  fi

  ACA_SUBNET_ID="$(printf '%s' "$existing" | jq -r '.id')"
  prefix="$(printf '%s' "$existing" | jq -r '.addressPrefix // (.addressPrefixes // [] | join(","))')"
  if [ "$prefix" != "$ACA_SUBNET_PREFIX" ]; then
    die "subnet ${ACA_SUBNET_NAME} is '${prefix}' but the configuration expects '${ACA_SUBNET_PREFIX}'; resolve this by hand"
  fi

  delegation="$(printf '%s' "$existing" | jq -r '[.delegations[]?.serviceName] | join(",")')"
  case ",${delegation}," in
    *",Microsoft.App/environments,"*)
      ok "subnet ${ACA_SUBNET_NAME} is already delegated to Microsoft.App/environments"
      ;;
    *)
      log "subnet ${ACA_SUBNET_NAME} is delegated to '${delegation:-nothing}'; delegating it to Microsoft.App/environments"
      az_do network vnet subnet update \
        --name "$ACA_SUBNET_NAME" \
        --vnet-name "$VNET_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --delegations Microsoft.App/environments --output none >/dev/null
      ;;
  esac
}

ensure_private_endpoint_subnet() {
  local existing prefix policies
  existing="$(azval network vnet subnet show \
    --name "$PRIVATE_ENDPOINT_SUBNET_NAME" --vnet-name "$VNET_NAME" --resource-group "$RESOURCE_GROUP" \
    --output json 2>/dev/null || true)"

  if [ -z "$existing" ]; then
    log "creating private endpoint subnet ${PRIVATE_ENDPOINT_SUBNET_NAME} (${PRIVATE_ENDPOINT_SUBNET_PREFIX})"
    PRIVATE_ENDPOINT_SUBNET_ID="$(az_do network vnet subnet create \
      --name "$PRIVATE_ENDPOINT_SUBNET_NAME" \
      --vnet-name "$VNET_NAME" \
      --resource-group "$RESOURCE_GROUP" \
      --address-prefixes "$PRIVATE_ENDPOINT_SUBNET_PREFIX" \
      --disable-private-endpoint-network-policies true \
      --query id --output tsv)"
    return 0
  fi

  PRIVATE_ENDPOINT_SUBNET_ID="$(printf '%s' "$existing" | jq -r '.id')"
  prefix="$(printf '%s' "$existing" | jq -r '.addressPrefix // (.addressPrefixes // [] | join(","))')"
  if [ "$prefix" != "$PRIVATE_ENDPOINT_SUBNET_PREFIX" ]; then
    die "subnet ${PRIVATE_ENDPOINT_SUBNET_NAME} is '${prefix}' but the configuration expects '${PRIVATE_ENDPOINT_SUBNET_PREFIX}'; resolve this by hand"
  fi

  policies="$(lowercase "$(printf '%s' "$existing" | jq -r '.privateEndpointNetworkPolicies // ""')")"
  if [ "$policies" = "disabled" ]; then
    ok "subnet ${PRIVATE_ENDPOINT_SUBNET_NAME} already has private endpoint network policies disabled"
  else
    log "disabling private endpoint network policies on ${PRIVATE_ENDPOINT_SUBNET_NAME}"
    az_do network vnet subnet update \
      --name "$PRIVATE_ENDPOINT_SUBNET_NAME" \
      --vnet-name "$VNET_NAME" \
      --resource-group "$RESOURCE_GROUP" \
      --disable-private-endpoint-network-policies true --output none >/dev/null
  fi
}

ensure_log_analytics_workspace() {
  local existing
  existing="$(azval monitor log-analytics workspace show \
    --workspace-name "$LOG_ANALYTICS_NAME" --resource-group "$RESOURCE_GROUP" \
    --output json 2>/dev/null || true)"

  if [ -n "$existing" ]; then
    LOG_ANALYTICS_ID="$(printf '%s' "$existing" | jq -r '.id')"
    ok "Log Analytics workspace ${LOG_ANALYTICS_NAME} already exists"
  else
    log "creating Log Analytics workspace ${LOG_ANALYTICS_NAME}"
    LOG_ANALYTICS_ID="$(az_do monitor log-analytics workspace create \
      --workspace-name "$LOG_ANALYTICS_NAME" \
      --resource-group "$RESOURCE_GROUP" \
      --location "$ACA_LOCATION" \
      --retention-time "$LOG_ANALYTICS_RETENTION_DAYS" \
      --query id --output tsv)"
  fi

  ensure_tags "$LOG_ANALYTICS_ID" "${ENVIRONMENT_TAGS[@]}"
}

ensure_application_insights() {
  local existing workspace
  existing="$(azval monitor app-insights component show \
    --app "$APP_INSIGHTS_NAME" --resource-group "$RESOURCE_GROUP" \
    --output json 2>/dev/null || true)"

  if [ -z "$existing" ]; then
    log "creating workspace-based Application Insights ${APP_INSIGHTS_NAME}"
    APP_INSIGHTS_ID="$(az_do monitor app-insights component create \
      --app "$APP_INSIGHTS_NAME" \
      --resource-group "$RESOURCE_GROUP" \
      --location "$ACA_LOCATION" \
      --workspace "$LOG_ANALYTICS_ID" \
      --kind web \
      --application-type web \
      --query id --output tsv)"
  else
    APP_INSIGHTS_ID="$(printf '%s' "$existing" | jq -r '.id')"
    workspace="$(printf '%s' "$existing" | jq -r '.workspaceResourceId // ""')"
    if [ "$(lowercase "$workspace")" != "$(lowercase "$LOG_ANALYTICS_ID")" ]; then
      # A classic (key-based) component reports no workspace at all; linking it
      # converts it to workspace-based, which is what the backend expects.
      log "linking Application Insights ${APP_INSIGHTS_NAME} to ${LOG_ANALYTICS_NAME}"
      az_do monitor app-insights component update \
        --app "$APP_INSIGHTS_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --workspace "$LOG_ANALYTICS_ID" --output none >/dev/null
    fi
    ok "Application Insights ${APP_INSIGHTS_NAME} already exists"
  fi

  ensure_tags "$APP_INSIGHTS_ID" "${ENVIRONMENT_TAGS[@]}"
}

ensure_container_apps_environment() {
  local existing internal public_access
  existing="$(azval containerapp env show \
    --name "$ACA_ENVIRONMENT_NAME" --resource-group "$RESOURCE_GROUP" \
    --output json 2>/dev/null || true)"

  if [ -z "$existing" ]; then
    log "creating internal workload-profiles Container Apps environment ${ACA_ENVIRONMENT_NAME}"
    # --logs-destination azure-monitor keeps the Log Analytics shared key out of
    # this script; the diagnostic setting created later carries the logs.
    ACA_ENVIRONMENT_ID="$(az_do containerapp env create \
      --name "$ACA_ENVIRONMENT_NAME" \
      --resource-group "$RESOURCE_GROUP" \
      --location "$ACA_LOCATION" \
      --enable-workload-profiles true \
      --infrastructure-subnet-resource-id "$ACA_SUBNET_ID" \
      --internal-only true \
      --logs-destination azure-monitor \
      --query id --output tsv)"
  else
    ACA_ENVIRONMENT_ID="$(printf '%s' "$existing" | jq -r '.id')"
    internal="$(lowercase "$(printf '%s' "$existing" | jq -r '.properties.vnetConfiguration.internal // false')")"
    if [ "$internal" != "true" ]; then
      # Switching an existing environment to internal-only is not supported in
      # place; recreating it would delete every container app inside it.
      die "Container Apps environment ${ACA_ENVIRONMENT_NAME} has a public load balancer; it must be recreated as internal-only"
    fi
    ok "Container Apps environment ${ACA_ENVIRONMENT_NAME} already exists and is internal"
  fi

  public_access="$(lowercase "$(azval containerapp env show \
    --name "$ACA_ENVIRONMENT_NAME" --resource-group "$RESOURCE_GROUP" \
    --query 'properties.publicNetworkAccess' --output tsv 2>/dev/null || true)")"
  if [ -n "$public_access" ] && [ "$public_access" != "disabled" ]; then
    log "disabling public network access on ${ACA_ENVIRONMENT_NAME}"
    az_do containerapp env update \
      --name "$ACA_ENVIRONMENT_NAME" \
      --resource-group "$RESOURCE_GROUP" \
      --public-network-access Disabled --output none >/dev/null ||
      warn "could not disable public network access on ${ACA_ENVIRONMENT_NAME}; the environment is still internal-only, verify this before Task 13"
  fi

  ensure_tags "$ACA_ENVIRONMENT_ID" "${ENVIRONMENT_TAGS[@]}"
}

# ensure_managed_identity <name>
# Sets IDENTITY_ID, IDENTITY_PRINCIPAL_ID and IDENTITY_CLIENT_ID.
IDENTITY_ID=""
IDENTITY_PRINCIPAL_ID=""
IDENTITY_CLIENT_ID=""
ensure_managed_identity() {
  local name="${1:?ensure_managed_identity requires a name}"
  local existing

  IDENTITY_ID=""
  IDENTITY_PRINCIPAL_ID=""
  IDENTITY_CLIENT_ID=""

  existing="$(azval identity show \
    --name "$name" --resource-group "$RESOURCE_GROUP" \
    --output json 2>/dev/null || true)"

  if [ -z "$existing" ]; then
    log "creating user-assigned managed identity ${name}"
    existing="$(az_do identity create \
      --name "$name" \
      --resource-group "$RESOURCE_GROUP" \
      --location "$ACA_LOCATION" \
      --output json)"
  else
    ok "managed identity ${name} already exists"
  fi

  if [ -n "$existing" ]; then
    IDENTITY_ID="$(printf '%s' "$existing" | jq -r '.id // ""')"
    IDENTITY_PRINCIPAL_ID="$(printf '%s' "$existing" | jq -r '.principalId // ""')"
    IDENTITY_CLIENT_ID="$(printf '%s' "$existing" | jq -r '.clientId // ""')"
  fi

  ensure_tags "$IDENTITY_ID" "${ENVIRONMENT_TAGS[@]}"
}

ensure_runtime_identities() {
  ensure_managed_identity "$BACKEND_IDENTITY_NAME"
  BACKEND_IDENTITY_ID="$IDENTITY_ID"
  BACKEND_IDENTITY_PRINCIPAL_ID="$IDENTITY_PRINCIPAL_ID"
  BACKEND_IDENTITY_CLIENT_ID="$IDENTITY_CLIENT_ID"

  ensure_managed_identity "$FRONTEND_IDENTITY_NAME"
  FRONTEND_IDENTITY_ID="$IDENTITY_ID"
  FRONTEND_IDENTITY_PRINCIPAL_ID="$IDENTITY_PRINCIPAL_ID"
  FRONTEND_IDENTITY_CLIENT_ID="$IDENTITY_CLIENT_ID"
}

# ---------------------------------------------------------------------------
# Role assignments
# ---------------------------------------------------------------------------

# Both runtime identities pull their own image from the shared registry, so
# both need AcrPull - and nothing more.
ensure_registry_pull_role_assignments() {
  [ -n "$ACR_ID" ] || die "the container registry resource id is unknown"

  if [ -n "$BACKEND_IDENTITY_PRINCIPAL_ID" ]; then
    ensure_role_assignment "$BACKEND_IDENTITY_PRINCIPAL_ID" AcrPull "$ACR_ID"
  else
    warn "the backend identity has no principal id yet; skipping its AcrPull assignment"
  fi

  if [ -n "$FRONTEND_IDENTITY_PRINCIPAL_ID" ]; then
    ensure_role_assignment "$FRONTEND_IDENTITY_PRINCIPAL_ID" AcrPull "$ACR_ID"
  else
    warn "the frontend identity has no principal id yet; skipping its AcrPull assignment"
  fi
}

# Data-plane access is granted to the BACKEND identity only. This function is
# deliberately the single place in the repository that names these two roles,
# so a reviewer can confirm the frontend identity is never passed in.
ensure_backend_only_role_assignments() {
  if [ -z "$BACKEND_IDENTITY_PRINCIPAL_ID" ]; then
    warn "the backend identity has no principal id yet; skipping its data-plane role assignments"
    return 0
  fi

  # Reading cost data for the whole subscription is the backend's core job.
  ensure_role_assignment "$BACKEND_IDENTITY_PRINCIPAL_ID" \
    "Cost Management Reader" "/subscriptions/${AZURE_SUBSCRIPTION_ID}"

  # Scoped to the single Foundry account, not to the resource group and not to
  # the subscription.
  ensure_role_assignment "$BACKEND_IDENTITY_PRINCIPAL_ID" \
    "Cognitive Services OpenAI User" "$FOUNDRY_ACCOUNT_ID"
}

# ---------------------------------------------------------------------------
# Container apps
# ---------------------------------------------------------------------------

# ensure_container_app <app name> <identity resource id>
# Sets CONTAINER_APP_ID.
CONTAINER_APP_ID=""
ensure_container_app() {
  local app_name="${1:?ensure_container_app requires an app name}"
  local identity_id="${2:?ensure_container_app requires an identity resource id}"
  local existing assigned registry_identity

  CONTAINER_APP_ID=""

  existing="$(azval containerapp show \
    --name "$app_name" --resource-group "$RESOURCE_GROUP" \
    --output json 2>/dev/null || true)"

  if [ -z "$existing" ]; then
    log "creating container app ${app_name} from the bootstrap image ${BOOTSTRAP_IMAGE}"
    # Ingress is internal: the environment has no public load balancer and
    # Front Door reaches these apps over a private link in Task 13.
    CONTAINER_APP_ID="$(az_do containerapp create \
      --name "$app_name" \
      --resource-group "$RESOURCE_GROUP" \
      --environment "$ACA_ENVIRONMENT_NAME" \
      --workload-profile-name "$ACA_WORKLOAD_PROFILE_NAME" \
      --image "$BOOTSTRAP_IMAGE" \
      --ingress internal \
      --target-port "$BOOTSTRAP_TARGET_PORT" \
      --min-replicas "$ACA_MIN_REPLICAS" \
      --max-replicas "$ACA_MAX_REPLICAS" \
      --user-assigned "$identity_id" \
      --query id --output tsv)"
  else
    CONTAINER_APP_ID="$(printf '%s' "$existing" | jq -r '.id')"
    # The image, the target port and the replica counts belong to the
    # deployment workflows; provisioning must not roll a running app back to
    # the bootstrap image.
    assigned="$(printf '%s' "$existing" |
      jq -r --arg id "$(lowercase "$identity_id")" \
        '[(.identity.userAssignedIdentities // {} | keys[]) | ascii_downcase] | any(. == $id)')"
    if [ "$assigned" != "true" ]; then
      log "attaching identity ${identity_id} to container app ${app_name}"
      az_do containerapp identity assign \
        --name "$app_name" \
        --resource-group "$RESOURCE_GROUP" \
        --user-assigned "$identity_id" --output none >/dev/null
    fi
    ok "container app ${app_name} already exists"
  fi

  # Managed-identity pull: the app authenticates to the registry with its own
  # user-assigned identity, so no registry password is ever stored.
  registry_identity="$(lowercase "$(azval containerapp show \
    --name "$app_name" --resource-group "$RESOURCE_GROUP" \
    --query "properties.configuration.registries[?server=='${ACR_LOGIN_SERVER}'].identity | [0]" \
    --output tsv 2>/dev/null || true)")"
  if [ "$registry_identity" != "$(lowercase "$identity_id")" ]; then
    log "configuring managed-identity pull from ${ACR_LOGIN_SERVER} for ${app_name}"
    az_do containerapp registry set \
      --name "$app_name" \
      --resource-group "$RESOURCE_GROUP" \
      --server "$ACR_LOGIN_SERVER" \
      --identity "$identity_id" --output none >/dev/null
  fi

  ensure_tags "$CONTAINER_APP_ID" "${ENVIRONMENT_TAGS[@]}"
}

ensure_container_apps() {
  ensure_container_app "$BACKEND_APP_NAME" "$BACKEND_IDENTITY_ID"
  BACKEND_APP_ID="$CONTAINER_APP_ID"

  ensure_container_app "$FRONTEND_APP_NAME" "$FRONTEND_IDENTITY_ID"
  FRONTEND_APP_ID="$CONTAINER_APP_ID"
}

# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------

# ensure_diagnostic_setting <resource id>
#
# The available categories differ per resource type and change over time, so
# they are discovered instead of hard coded. `az monitor diagnostic-settings
# create` is a PUT, which makes it safe to re-issue when the destination drifts.
ensure_diagnostic_setting() {
  local resource_id="${1:-}"
  local categories logs metrics existing logs_file metrics_file
  local -a args=()

  if [ -z "$resource_id" ] || [ -z "$LOG_ANALYTICS_ID" ]; then
    return 0
  fi

  categories="$(azval monitor diagnostic-settings categories list \
    --resource "$resource_id" --output json 2>/dev/null || true)"
  if [ -z "$categories" ]; then
    warn "no diagnostic categories are published for ${resource_id}; skipping its diagnostic setting"
    return 0
  fi

  logs="$(printf '%s' "$categories" |
    jq -c '(if type == "array" then . else (.value // []) end)
           | [ .[] | select(.categoryType == "Logs") | { category: .name, enabled: true } ]')"
  metrics="$(printf '%s' "$categories" |
    jq -c '(if type == "array" then . else (.value // []) end)
           | [ .[] | select(.categoryType == "Metrics") | { category: .name, enabled: true } ]')"

  if [ "$logs" = "[]" ] && [ "$metrics" = "[]" ]; then
    warn "no diagnostic categories are published for ${resource_id}; skipping its diagnostic setting"
    return 0
  fi

  existing="$(azval monitor diagnostic-settings show \
    --name "$DIAGNOSTIC_SETTING_NAME" --resource "$resource_id" \
    --query workspaceId --output tsv 2>/dev/null || true)"
  if [ "$(lowercase "$existing")" = "$(lowercase "$LOG_ANALYTICS_ID")" ]; then
    ok "diagnostic setting ${DIAGNOSTIC_SETTING_NAME} on ${resource_id} already targets ${LOG_ANALYTICS_NAME}"
    return 0
  fi

  # The category lists are passed as files: az reads @<path> for any argument,
  # which avoids quoting JSON through the WSL/cmd.exe argument boundary.
  if [ "$logs" != "[]" ]; then
    az_body_file "$logs" || die "could not stage the diagnostic log categories for ${resource_id}"
    logs_file="$AZ_BODY_FILE"
    args+=(--logs "@${logs_file}")
  fi
  if [ "$metrics" != "[]" ]; then
    az_body_file "$metrics" || die "could not stage the diagnostic metric categories for ${resource_id}"
    metrics_file="$AZ_BODY_FILE"
    args+=(--metrics "@${metrics_file}")
  fi

  log "sending diagnostics for ${resource_id} to ${LOG_ANALYTICS_NAME}"
  az_do monitor diagnostic-settings create \
    --name "$DIAGNOSTIC_SETTING_NAME" \
    --resource "$resource_id" \
    --workspace "$LOG_ANALYTICS_ID" \
    "${args[@]}" --output none >/dev/null
}

ensure_diagnostic_settings() {
  local resource_id
  for resource_id in \
    "$ACA_ENVIRONMENT_ID" \
    "$BACKEND_APP_ID" \
    "$FRONTEND_APP_ID" \
    "$APP_INSIGHTS_ID"; do
    ensure_diagnostic_setting "$resource_id"
  done
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

emit_output() {
  # Identity client IDs are not secrets and the deployment workflows need them;
  # the Application Insights connection string is a credential and is not
  # printed here.
  jq -n \
    --arg environment "$APP_ENVIRONMENT" \
    --arg subscriptionId "$AZURE_SUBSCRIPTION_ID" \
    --arg location "$ACA_LOCATION" \
    --arg resourceGroup "$RESOURCE_GROUP" \
    --arg resourceGroupId "$RESOURCE_GROUP_ID" \
    --arg vnetId "$VNET_ID" \
    --arg acaSubnetId "$ACA_SUBNET_ID" \
    --arg privateEndpointSubnetId "$PRIVATE_ENDPOINT_SUBNET_ID" \
    --arg logAnalyticsName "$LOG_ANALYTICS_NAME" \
    --arg logAnalyticsId "$LOG_ANALYTICS_ID" \
    --arg appInsightsName "$APP_INSIGHTS_NAME" \
    --arg appInsightsId "$APP_INSIGHTS_ID" \
    --arg acaEnvironmentName "$ACA_ENVIRONMENT_NAME" \
    --arg acaEnvironmentId "$ACA_ENVIRONMENT_ID" \
    --arg registryLoginServer "$ACR_LOGIN_SERVER" \
    --arg backendAppName "$BACKEND_APP_NAME" \
    --arg backendAppId "$BACKEND_APP_ID" \
    --arg backendIdentityId "$BACKEND_IDENTITY_ID" \
    --arg backendIdentityClientId "$BACKEND_IDENTITY_CLIENT_ID" \
    --arg backendIdentityPrincipalId "$BACKEND_IDENTITY_PRINCIPAL_ID" \
    --arg frontendAppName "$FRONTEND_APP_NAME" \
    --arg frontendAppId "$FRONTEND_APP_ID" \
    --arg frontendIdentityId "$FRONTEND_IDENTITY_ID" \
    --arg frontendIdentityClientId "$FRONTEND_IDENTITY_CLIENT_ID" \
    --arg frontendIdentityPrincipalId "$FRONTEND_IDENTITY_PRINCIPAL_ID" \
    --arg foundryAccountId "$FOUNDRY_ACCOUNT_ID" \
    '{
      environment: $environment,
      subscriptionId: $subscriptionId,
      location: $location,
      resourceGroup: { name: $resourceGroup, id: $resourceGroupId },
      network: {
        vnetId: $vnetId,
        containerAppsSubnetId: $acaSubnetId,
        privateEndpointSubnetId: $privateEndpointSubnetId
      },
      observability: {
        logAnalytics: { name: $logAnalyticsName, id: $logAnalyticsId },
        applicationInsights: { name: $appInsightsName, id: $appInsightsId }
      },
      containerAppsEnvironment: {
        name: $acaEnvironmentName,
        id: $acaEnvironmentId,
        internalOnly: true,
        workloadProfilesEnabled: true
      },
      registryLoginServer: $registryLoginServer,
      backend: {
        appName: $backendAppName,
        appId: $backendAppId,
        identityId: $backendIdentityId,
        identityClientId: $backendIdentityClientId,
        identityPrincipalId: $backendIdentityPrincipalId,
        roles: [
          { role: "AcrPull", scope: "registry" },
          { role: "Cost Management Reader", scope: ("/subscriptions/" + $subscriptionId) },
          { role: "Cognitive Services OpenAI User", scope: $foundryAccountId }
        ]
      },
      frontend: {
        appName: $frontendAppName,
        appId: $frontendAppId,
        identityId: $frontendIdentityId,
        identityClientId: $frontendIdentityClientId,
        identityPrincipalId: $frontendIdentityPrincipalId,
        roles: [ { role: "AcrPull", scope: "registry" } ]
      }
    }'
}

# ---------------------------------------------------------------------------

main() {
  parse_environment_argument "${1:-}"
  log "provisioning the ${TARGET_ENVIRONMENT} environment"
  require_cmd az jq || die "install the missing command-line tools and re-run"
  load_environment_config
  require_azure_context
  ensure_az_extension containerapp application-insights
  resolve_shared_dependencies

  ensure_environment_resource_group
  ensure_virtual_network
  ensure_aca_subnet
  ensure_private_endpoint_subnet
  ensure_log_analytics_workspace
  ensure_application_insights
  ensure_container_apps_environment
  ensure_runtime_identities
  ensure_registry_pull_role_assignments
  ensure_backend_only_role_assignments
  ensure_container_apps
  ensure_diagnostic_settings

  ok "the ${TARGET_ENVIRONMENT} environment is provisioned"
  emit_output
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
