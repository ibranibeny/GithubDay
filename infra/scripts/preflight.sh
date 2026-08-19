#!/usr/bin/env bash
#
# preflight.sh - read-only readiness check for the Azure Cost Copilot workshop.
#
# This script never creates, updates or deletes anything. It only reads Azure
# state and prints either the single word READY on stdout or a list of blockers.
#
# Usage:
#   export WORKSHOP_GROUP_OBJECT_ID=<object id of the workshop Entra ID group>
#   bash infra/scripts/preflight.sh
#
# Exit codes: 0 = READY, 1 = at least one blocker.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
. "${SCRIPT_DIR}/lib.sh"

INFRA_CONFIG_DIR="${INFRA_CONFIG_DIR:-${SCRIPT_DIR}/../config}"

# Minimum tool versions. az 2.61 is the first release with the Container Apps,
# Front Door Standard/Premium and federated-credential commands used later.
AZ_MIN_VERSION="${AZ_MIN_VERSION:-2.61.0}"
GH_MIN_VERSION="${GH_MIN_VERSION:-2.40.0}"
JQ_MIN_VERSION="${JQ_MIN_VERSION:-1.6}"

# Verified live against this subscription in the design phase.
COST_API_VERSION="${COST_API_VERSION:-2026-06-01}"
CDN_API_VERSION="${CDN_API_VERSION:-2024-02-01}"

REQUIRED_PROVIDERS=(
  Microsoft.App
  Microsoft.OperationalInsights
  Microsoft.Insights
  Microsoft.Cdn
  Microsoft.ContainerRegistry
  Microsoft.CognitiveServices
)

declare -a BLOCKERS=()

blocker() {
  BLOCKERS+=("$1")
  err "$1"
}

trap cleanup_temp_files EXIT

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

check_cli_tools() {
  require_cmd az gh jq || die "install the missing command-line tools and re-run"

  local raw version

  raw="$(azval version --output tsv --query '"azure-cli"' 2>/dev/null || true)"
  version="$(extract_version "$raw" || true)"
  if [ -z "$version" ]; then
    blocker "could not read the Azure CLI version from 'az version'"
  elif ! version_ge "$version" "$AZ_MIN_VERSION"; then
    blocker "azure-cli ${version} is older than the required ${AZ_MIN_VERSION}"
  else
    ok "azure-cli ${version}"
  fi

  raw="$(gh --version 2>/dev/null | tr -d '\r' | head -n 1 || true)"
  version="$(extract_version "$raw" || true)"
  if [ -z "$version" ]; then
    blocker "could not read the GitHub CLI version from 'gh --version'"
  elif ! version_ge "$version" "$GH_MIN_VERSION"; then
    blocker "gh ${version} is older than the required ${GH_MIN_VERSION}"
  else
    ok "gh ${version}"
  fi

  raw="$(jq --version 2>/dev/null | tr -d '\r' || true)"
  version="$(extract_version "$raw" || true)"
  if [ -z "$version" ]; then
    blocker "could not read the jq version from 'jq --version'"
  elif ! version_ge "$version" "$JQ_MIN_VERSION"; then
    blocker "jq ${version} is older than the required ${JQ_MIN_VERSION}"
  else
    ok "jq ${version}"
  fi
}

check_required_inputs() {
  if [ -z "${WORKSHOP_GROUP_OBJECT_ID:-}" ]; then
    die "WORKSHOP_GROUP_OBJECT_ID is not set. It is an operator input: export the object ID of the Entra ID group that receives the Cost.Read app role, then re-run."
  fi
  if ! is_guid "$WORKSHOP_GROUP_OBJECT_ID"; then
    die "WORKSHOP_GROUP_OBJECT_ID is not a GUID; expected the Entra ID group object ID."
  fi
  ok "workshop group object id supplied"
}

check_providers() {
  local namespace state
  for namespace in "${REQUIRED_PROVIDERS[@]}"; do
    state="$(azval provider show --namespace "$namespace" --query registrationState --output tsv 2>/dev/null || true)"
    case "$state" in
      Registered)
        ok "resource provider ${namespace} is registered"
        ;;
      '')
        blocker "could not read the registration state of resource provider ${namespace}"
        ;;
      *)
        blocker "resource provider ${namespace} is '${state}'; run: az provider register --namespace ${namespace}"
        ;;
    esac
  done
}

check_aca_region() {
  local locations normalized want
  want="$(lowercase "${ACA_LOCATION}")"
  locations="$(azval provider show --namespace Microsoft.App \
    --query "resourceTypes[?resourceType=='managedEnvironments'].locations[]" \
    --output tsv 2>/dev/null || true)"
  if [ -z "$locations" ]; then
    blocker "could not list the regions that support Container Apps managed environments"
    return 0
  fi
  # The provider API returns display names such as "Indonesia Central".
  # Only spaces and tabs are removed; the newlines separate the regions.
  normalized="$(printf '%s\n' "$locations" | tr '[:upper:]' '[:lower:]' | tr -d ' \t')"
  if printf '%s\n' "$normalized" | grep -Fxq -- "$want"; then
    ok "Container Apps is available in ${ACA_LOCATION}"
  else
    blocker "Container Apps managed environments are not available in ${ACA_LOCATION}"
  fi
}

check_caller_roles() {
  local object_id roles
  object_id="$(azval ad signed-in-user show --query id --output tsv 2>/dev/null || true)"
  if [ -z "$object_id" ]; then
    warn "skipping the role check: 'az ad signed-in-user show' returned nothing (expected when signed in as a service principal or a federated workflow identity)"
    return 0
  fi
  roles="$(azval role assignment list \
    --assignee "$object_id" \
    --scope "/subscriptions/${AZURE_SUBSCRIPTION_ID}" \
    --include-inherited --include-groups \
    --query "[].roleDefinitionName" --output tsv 2>/dev/null || true)"
  if [ -z "$roles" ]; then
    warn "no subscription role assignments were readable for the caller; provisioning may fail later"
    return 0
  fi
  if printf '%s\n' "$roles" | grep -Eq '^(Owner|Contributor)$'; then
    ok "caller holds a subscription role that can provision resources"
  else
    warn "caller does not hold Owner or Contributor on the subscription; provisioning may fail later"
  fi
  if printf '%s\n' "$roles" | grep -Eq '^(Owner|User Access Administrator|Role Based Access Control Administrator)$'; then
    ok "caller can create the role assignments the runtime identities need"
  else
    warn "caller cannot create role assignments (needs Owner, User Access Administrator or Role Based Access Control Administrator); Cost Management Reader and Cognitive Services OpenAI User grants will fail"
  fi
}

check_shared_names() {
  local staging_config="${INFRA_CONFIG_DIR}/staging.env"
  local production_config="${INFRA_CONFIG_DIR}/production.env"
  local key staging_value production_value

  for key in SHARED_RESOURCE_GROUP ACR_NAME AFD_PROFILE_NAME; do
    staging_value="$(config_value "$staging_config" "$key" || true)"
    production_value="$(config_value "$production_config" "$key" || true)"
    if [ -z "$staging_value" ] || [ -z "$production_value" ]; then
      blocker "${key} is missing from staging.env or production.env"
    elif [ "$staging_value" != "$production_value" ]; then
      blocker "${key} differs between staging.env ('${staging_value}') and production.env ('${production_value}'); shared resources must match"
    fi
  done

  local shared_group registry_name
  shared_group="$(config_value "$staging_config" SHARED_RESOURCE_GROUP || true)"
  registry_name="$(config_value "$staging_config" ACR_NAME || true)"
  if [ -n "$registry_name" ]; then
    check_acr_name "$registry_name" "$shared_group"
  fi

  local environment endpoint
  for environment in staging production; do
    endpoint="$(config_value "${INFRA_CONFIG_DIR}/${environment}.env" AFD_ENDPOINT_NAME || true)"
    if [ -z "$endpoint" ]; then
      blocker "AFD_ENDPOINT_NAME is missing from ${environment}.env"
    else
      check_afd_endpoint_name "$endpoint"
    fi
  done
}

check_acr_name() {
  local name="$1" resource_group="$2" available
  if [ -n "$resource_group" ] &&
    azval acr show --name "$name" --resource-group "$resource_group" --query id --output tsv >/dev/null 2>&1; then
    ok "container registry ${name} already exists in ${resource_group}"
    return 0
  fi
  available="$(azval acr check-name --name "$name" --query nameAvailable --output tsv 2>/dev/null || true)"
  case "$available" in
    true | True)
      ok "container registry name ${name} is available"
      ;;
    false | False)
      blocker "container registry name ${name} is already taken; change ACR_NAME in staging.env and production.env"
      ;;
    *)
      warn "could not determine whether the container registry name ${name} is available"
      ;;
  esac
}

check_afd_endpoint_name() {
  local name="$1" profile available
  profile="$(config_value "${INFRA_CONFIG_DIR}/staging.env" AFD_PROFILE_NAME || true)"
  local shared_group
  shared_group="$(config_value "${INFRA_CONFIG_DIR}/staging.env" SHARED_RESOURCE_GROUP || true)"

  if [ -n "$profile" ] && [ -n "$shared_group" ] &&
    azval afd endpoint show --endpoint-name "$name" --profile-name "$profile" \
      --resource-group "$shared_group" --query id --output tsv >/dev/null 2>&1; then
    ok "Front Door endpoint ${name} already exists in profile ${profile}"
    return 0
  fi

  if ! az_body_file "$(printf '{"name":"%s","type":"Microsoft.Cdn/Profiles/AfdEndpoints"}' "$name")"; then
    warn "could not stage the Front Door name-availability request for ${name}"
    return 0
  fi
  available="$(azval rest --method post \
    --url "https://management.azure.com/subscriptions/${AZURE_SUBSCRIPTION_ID}/providers/Microsoft.Cdn/checkNameAvailability?api-version=${CDN_API_VERSION}" \
    --body "@${AZ_BODY_FILE}" --query nameAvailable --output tsv 2>/dev/null || true)"
  case "$available" in
    true | True)
      ok "Front Door endpoint name ${name} is available"
      ;;
    false | False)
      # Endpoint host names are hash-suffixed, so a taken name is unusual but
      # still worth flagging before Task 13 tries to create it.
      blocker "Front Door endpoint name ${name} is already taken; change AFD_ENDPOINT_NAME"
      ;;
    *)
      warn "could not determine whether the Front Door endpoint name ${name} is available (advisory only: endpoint host names carry a generated hash suffix)"
      ;;
  esac
}

check_foundry() {
  local state deployment_state capacity endpoint

  state="$(azval cognitiveservices account show \
    --name "$FOUNDRY_ACCOUNT_NAME" --resource-group "$FOUNDRY_RESOURCE_GROUP" \
    --query "properties.provisioningState" --output tsv 2>/dev/null || true)"
  if [ "$state" != "Succeeded" ]; then
    blocker "Foundry account ${FOUNDRY_RESOURCE_GROUP}/${FOUNDRY_ACCOUNT_NAME} is '${state:-not found}', expected 'Succeeded'"
    return 0
  fi
  endpoint="$(azval cognitiveservices account show \
    --name "$FOUNDRY_ACCOUNT_NAME" --resource-group "$FOUNDRY_RESOURCE_GROUP" \
    --query "properties.endpoint" --output tsv 2>/dev/null || true)"
  ok "Foundry account ${FOUNDRY_ACCOUNT_NAME} is ready at ${endpoint:-<unknown endpoint>}"

  deployment_state="$(azval cognitiveservices account deployment show \
    --name "$FOUNDRY_ACCOUNT_NAME" --resource-group "$FOUNDRY_RESOURCE_GROUP" \
    --deployment-name "$FOUNDRY_DEPLOYMENT" \
    --query "properties.provisioningState" --output tsv 2>/dev/null || true)"
  if [ "$deployment_state" != "Succeeded" ]; then
    blocker "model deployment '${FOUNDRY_DEPLOYMENT}' on ${FOUNDRY_ACCOUNT_NAME} is '${deployment_state:-not found}', expected 'Succeeded'"
    return 0
  fi
  ok "model deployment ${FOUNDRY_DEPLOYMENT} is Succeeded"

  capacity="$(azval cognitiveservices account deployment show \
    --name "$FOUNDRY_ACCOUNT_NAME" --resource-group "$FOUNDRY_RESOURCE_GROUP" \
    --deployment-name "$FOUNDRY_DEPLOYMENT" \
    --query "sku.capacity" --output tsv 2>/dev/null || true)"
  if [[ "$capacity" =~ ^[0-9]+$ ]] && [ "$capacity" -gt 0 ]; then
    ok "model deployment ${FOUNDRY_DEPLOYMENT} has quota capacity ${capacity}"
  else
    blocker "model deployment ${FOUNDRY_DEPLOYMENT} reports no usable quota (capacity '${capacity:-unknown}')"
  fi
}

check_cost_management() {
  local from_date to_date payload

  from_date="$(date -u -d '1 day ago' +%Y-%m-%d 2>/dev/null || date -u +%Y-%m-%d)"
  to_date="$(date -u +%Y-%m-%d)"
  payload="$(
    cat <<JSON
{"type":"ActualCost","timeframe":"Custom","timePeriod":{"from":"${from_date}T00:00:00Z","to":"${to_date}T00:00:00Z"},"dataset":{"granularity":"None","aggregation":{"totalCost":{"name":"Cost","function":"Sum"}}}}
JSON
  )"

  if az_body_file "$payload" &&
    azval rest --method post \
      --url "https://management.azure.com/subscriptions/${AZURE_SUBSCRIPTION_ID}/providers/Microsoft.CostManagement/query?api-version=${COST_API_VERSION}" \
      --body "@${AZ_BODY_FILE}" >/dev/null 2>&1; then
    ok "Cost Management query API is readable for the subscription"
    return 0
  fi

  # Fall back to a body-less read so a request-shape problem is not reported as
  # a permission problem.
  if azval rest --method get \
    --url "https://management.azure.com/subscriptions/${AZURE_SUBSCRIPTION_ID}/providers/Microsoft.CostManagement/dimensions?api-version=${COST_API_VERSION}&\$top=1" \
    >/dev/null 2>&1; then
    warn "the Cost Management query POST failed but the dimensions read succeeded; check the query body shape before Task 12"
    return 0
  fi

  blocker "Cost Management is not readable for subscription ${AZURE_SUBSCRIPTION_ID}; the caller needs Cost Management Reader or higher"
}

check_github_cli() {
  if ! gh auth status >/dev/null 2>&1; then
    blocker "the GitHub CLI is not authenticated; run 'gh auth login' or export GH_TOKEN before the bootstrap"
    return 0
  fi
  ok "GitHub CLI is authenticated"

  local repository="${GITHUB_OWNER}/${GITHUB_REPOSITORY}"
  if gh repo view "$repository" --json name >/dev/null 2>&1; then
    ok "repository ${repository} is reachable"
  else
    warn "repository ${repository} is not readable with the current GitHub token"
  fi
}

report() {
  if [ "${#BLOCKERS[@]}" -eq 0 ]; then
    ok "preflight found no blockers"
    printf 'READY\n'
    return 0
  fi
  err "preflight found ${#BLOCKERS[@]} blocker(s):"
  local item
  for item in "${BLOCKERS[@]}"; do
    printf 'BLOCKER: %s\n' "$item"
  done
  return 1
}

main() {
  log "Azure Cost Copilot preflight (read-only; nothing is created or changed)"
  load_config "${INFRA_CONFIG_DIR}/shared.env"

  check_cli_tools
  require_azure_context
  check_required_inputs
  check_providers
  check_aca_region
  check_caller_roles
  check_shared_names
  check_foundry
  check_cost_management
  check_github_cli

  report
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
