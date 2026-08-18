#!/usr/bin/env bash
#
# verify.sh - prove that a deployed Azure Cost Copilot environment is actually
# the environment that was designed.
#
#   bash infra/scripts/verify.sh staging
#   bash infra/scripts/verify.sh staging <frontend-image@sha256:...> <backend-image@sha256:...>
#   FRONTEND_IMAGE=... BACKEND_IMAGE=... bash infra/scripts/verify.sh production
#
# Every check is read-only: this script calls no mutating Azure command and
# never uses az_do. Run it after deploy.sh, and run it again whenever somebody
# says "but it works".
#
# Checks, in order:
#
#   1. both container apps carry their own user-assigned identity
#   2. the backend identity holds Cost Management Reader and Cognitive Services
#      OpenAI User - and the frontend identity holds NEITHER
#   3. the running images are pinned by digest and match what was requested
#   4. Front Door serves /api/* and /health/* from the backend origin group and
#      /* from the frontend one, with the backend patterns the more specific
#      (winning) ones
#   5. the Private Link connections into the managed environment are Approved
#   6. the Front Door endpoint answers /health/live with 200 and serves the SPA
#   7. the diagnostic settings exist
#   8. Application Insights received a request in the last N minutes
#
# Failures are collected rather than fatal one at a time, so a single run
# reports everything that is wrong. The exit status is non-zero if anything
# failed.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
. "${SCRIPT_DIR}/lib.sh"

INFRA_CONFIG_DIR="${INFRA_CONFIG_DIR:-${SCRIPT_DIR}/../config}"

readonly DIGEST_PATTERN='^[A-Za-z0-9][A-Za-z0-9._/:-]*@sha256:[0-9a-f]{64}$'

# Roles the backend needs and the frontend must never have.
readonly COST_ROLE="Cost Management Reader"
readonly FOUNDRY_ROLE="Cognitive Services OpenAI User"

TARGET_ENVIRONMENT=""
EXPECTED_FRONTEND_IMAGE=""
EXPECTED_BACKEND_IMAGE=""

FAILURES=0
CHECKS=0

ACA_ENVIRONMENT_ID=""
AFD_PROFILE_ID=""
AFD_ENDPOINT_HOSTNAME=""
APP_INSIGHTS_ID=""
BACKEND_IDENTITY_ID=""
BACKEND_IDENTITY_PRINCIPAL_ID=""
FRONTEND_IDENTITY_ID=""
FRONTEND_IDENTITY_PRINCIPAL_ID=""
FOUNDRY_ACCOUNT_ID=""

trap cleanup_temp_files EXIT

# ---------------------------------------------------------------------------
# Result bookkeeping
# ---------------------------------------------------------------------------

pass() {
  CHECKS=$((CHECKS + 1))
  ok "$*"
}

fail() {
  CHECKS=$((CHECKS + 1))
  FAILURES=$((FAILURES + 1))
  err "$*"
}

# ---------------------------------------------------------------------------
# Arguments and configuration
# ---------------------------------------------------------------------------

parse_arguments() {
  local candidate="${1:-}"
  case "$candidate" in
    staging | production) TARGET_ENVIRONMENT="$candidate" ;;
    '') die "usage: verify.sh <staging|production> [frontend-image] [backend-image]" ;;
    *) die "unknown environment '${candidate}'; expected 'staging' or 'production'" ;;
  esac

  EXPECTED_FRONTEND_IMAGE="${2:-${FRONTEND_IMAGE:-}}"
  EXPECTED_BACKEND_IMAGE="${3:-${BACKEND_IMAGE:-}}"
}

load_environment_config() {
  load_config "${INFRA_CONFIG_DIR}/${TARGET_ENVIRONMENT}.env"
  load_config "${INFRA_CONFIG_DIR}/shared.env"

  require_env \
    AZURE_SUBSCRIPTION_ID AZURE_TENANT_ID APP_ENVIRONMENT \
    RESOURCE_GROUP SHARED_RESOURCE_GROUP \
    ACA_ENVIRONMENT_NAME BACKEND_APP_NAME FRONTEND_APP_NAME \
    BACKEND_IDENTITY_NAME FRONTEND_IDENTITY_NAME \
    AFD_PROFILE_NAME AFD_ENDPOINT_NAME \
    AFD_FRONTEND_ROUTE_NAME AFD_BACKEND_ROUTE_NAME AFD_HEALTH_ROUTE_NAME \
    AFD_FRONTEND_ROUTE_PATTERN AFD_BACKEND_ROUTE_PATTERN AFD_HEALTH_ROUTE_PATTERN \
    AFD_FRONTEND_ORIGIN_GROUP_NAME AFD_BACKEND_ORIGIN_GROUP_NAME \
    APP_INSIGHTS_NAME FOUNDRY_RESOURCE_GROUP FOUNDRY_ACCOUNT_NAME \
    VERIFY_TELEMETRY_WINDOW_MINUTES VERIFY_HEALTH_PATH ||
    die "the ${TARGET_ENVIRONMENT} configuration is incomplete"

  if [ "$APP_ENVIRONMENT" != "$TARGET_ENVIRONMENT" ]; then
    die "APP_ENVIRONMENT is '${APP_ENVIRONMENT}' but the requested environment is '${TARGET_ENVIRONMENT}'"
  fi
}

resolve_dependencies() {
  ACA_ENVIRONMENT_ID="$(azval containerapp env show \
    --name "$ACA_ENVIRONMENT_NAME" --resource-group "$RESOURCE_GROUP" \
    --query id --output tsv 2>/dev/null || true)"
  AFD_PROFILE_ID="$(azval afd profile show \
    --profile-name "$AFD_PROFILE_NAME" --resource-group "$SHARED_RESOURCE_GROUP" \
    --query id --output tsv 2>/dev/null || true)"
  AFD_ENDPOINT_HOSTNAME="$(azval afd endpoint show \
    --endpoint-name "$AFD_ENDPOINT_NAME" --profile-name "$AFD_PROFILE_NAME" \
    --resource-group "$SHARED_RESOURCE_GROUP" \
    --query hostName --output tsv 2>/dev/null || true)"
  APP_INSIGHTS_ID="$(azval monitor app-insights component show \
    --app "$APP_INSIGHTS_NAME" --resource-group "$RESOURCE_GROUP" \
    --query id --output tsv 2>/dev/null || true)"
  FOUNDRY_ACCOUNT_ID="$(azval cognitiveservices account show \
    --name "$FOUNDRY_ACCOUNT_NAME" --resource-group "$FOUNDRY_RESOURCE_GROUP" \
    --query id --output tsv 2>/dev/null || true)"

  BACKEND_IDENTITY_ID="$(azval identity show \
    --name "$BACKEND_IDENTITY_NAME" --resource-group "$RESOURCE_GROUP" \
    --query id --output tsv 2>/dev/null || true)"
  BACKEND_IDENTITY_PRINCIPAL_ID="$(azval identity show \
    --name "$BACKEND_IDENTITY_NAME" --resource-group "$RESOURCE_GROUP" \
    --query principalId --output tsv 2>/dev/null || true)"
  FRONTEND_IDENTITY_ID="$(azval identity show \
    --name "$FRONTEND_IDENTITY_NAME" --resource-group "$RESOURCE_GROUP" \
    --query id --output tsv 2>/dev/null || true)"
  FRONTEND_IDENTITY_PRINCIPAL_ID="$(azval identity show \
    --name "$FRONTEND_IDENTITY_NAME" --resource-group "$RESOURCE_GROUP" \
    --query principalId --output tsv 2>/dev/null || true)"
}

# ---------------------------------------------------------------------------
# 1. Runtime identities
# ---------------------------------------------------------------------------

# check_app_identity <app name> <expected identity resource id> <label>
check_app_identity() {
  local app_name="${1:?}" expected="${2:-}" label="${3:?}"
  local assigned

  if [ -z "$expected" ]; then
    fail "${label}: the expected user-assigned identity was not found in ${RESOURCE_GROUP}"
    return 0
  fi

  assigned="$(azval containerapp show \
    --name "$app_name" --resource-group "$RESOURCE_GROUP" \
    --query 'identity.userAssignedIdentities' --output json 2>/dev/null || true)"

  if [ -z "$assigned" ] || [ "$assigned" = "null" ]; then
    fail "${label}: container app ${app_name} has no user-assigned identity"
    return 0
  fi

  if [ "$(printf '%s' "$assigned" | jq -r --arg id "$(lowercase "$expected")" \
    '[ (keys[]) | ascii_downcase ] | any(. == $id)')" = "true" ]; then
    pass "${label}: ${app_name} runs as ${expected##*/}"
  else
    fail "${label}: ${app_name} does not carry the identity ${expected##*/}"
  fi
}

check_runtime_identities() {
  check_app_identity "$BACKEND_APP_NAME" "$BACKEND_IDENTITY_ID" backend
  check_app_identity "$FRONTEND_APP_NAME" "$FRONTEND_IDENTITY_ID" frontend
}

# ---------------------------------------------------------------------------
# 2. Least privilege
# ---------------------------------------------------------------------------

# roles_of <principal object id> - every role name assigned anywhere in the
# subscription, one per line. A single-field projection is used on purpose:
# a multi-field '[a,b]' projection would print one value per line as well and
# there would be no way to tell the columns apart.
roles_of() {
  local principal_id="${1:-}"
  [ -n "$principal_id" ] || return 0
  azval role assignment list \
    --all \
    --query "[?principalId=='${principal_id}'].roleDefinitionName" \
    --output tsv 2>/dev/null || true
}

check_least_privilege() {
  local backend_roles frontend_roles

  if [ -z "$BACKEND_IDENTITY_PRINCIPAL_ID" ]; then
    fail "least privilege: the backend identity has no principal id; its roles cannot be checked"
  else
    backend_roles="$(roles_of "$BACKEND_IDENTITY_PRINCIPAL_ID")"
    if printf '%s\n' "$backend_roles" | grep -qxF "$COST_ROLE"; then
      pass "backend identity holds '${COST_ROLE}'"
    else
      fail "backend identity is missing '${COST_ROLE}'; cost queries will fail"
    fi
    if printf '%s\n' "$backend_roles" | grep -qxF "$FOUNDRY_ROLE"; then
      pass "backend identity holds '${FOUNDRY_ROLE}'"
    else
      fail "backend identity is missing '${FOUNDRY_ROLE}'; model calls will fail"
    fi
  fi

  # The frontend serves static files. If it can read cost data or call the
  # model, the browser-facing tier has become a second copy of the backend's
  # blast radius, so this is a hard failure, not a warning.
  if [ -z "$FRONTEND_IDENTITY_PRINCIPAL_ID" ]; then
    fail "least privilege: the frontend identity has no principal id; its roles cannot be checked"
  else
    frontend_roles="$(roles_of "$FRONTEND_IDENTITY_PRINCIPAL_ID")"
    if printf '%s\n' "$frontend_roles" | grep -qxF "$COST_ROLE"; then
      fail "frontend identity holds '${COST_ROLE}'; it must hold NEITHER data-plane role"
    else
      pass "frontend identity does not hold '${COST_ROLE}'"
    fi
    if printf '%s\n' "$frontend_roles" | grep -qxF "$FOUNDRY_ROLE"; then
      fail "frontend identity holds '${FOUNDRY_ROLE}'; it must hold NEITHER data-plane role"
    else
      pass "frontend identity does not hold '${FOUNDRY_ROLE}'"
    fi
  fi
}

# ---------------------------------------------------------------------------
# 3. Running images
# ---------------------------------------------------------------------------

# check_running_image <app name> <expected reference> <label>
check_running_image() {
  local app_name="${1:?}" expected="${2:-}" label="${3:?}"
  local running

  running="$(azval containerapp show \
    --name "$app_name" --resource-group "$RESOURCE_GROUP" \
    --query 'properties.template.containers[0].image' --output tsv 2>/dev/null || true)"

  if [ -z "$running" ]; then
    fail "${label}: could not read the running image of ${app_name}"
    return 0
  fi

  if [[ "$running" =~ $DIGEST_PATTERN ]]; then
    pass "${label}: ${app_name} runs a digest-pinned image"
  else
    fail "${label}: ${app_name} runs '${running}', which is not pinned to a sha256 digest"
  fi

  if [ -z "$expected" ]; then
    log "${label}: no expected reference was supplied; only the digest pinning was checked"
    return 0
  fi

  if [ "$running" = "$expected" ]; then
    pass "${label}: ${app_name} runs the requested image"
  else
    fail "${label}: ${app_name} runs '${running}' but '${expected}' was requested"
  fi
}

check_running_images() {
  check_running_image "$BACKEND_APP_NAME" "$EXPECTED_BACKEND_IMAGE" backend
  check_running_image "$FRONTEND_APP_NAME" "$EXPECTED_FRONTEND_IMAGE" frontend
}

# ---------------------------------------------------------------------------
# 4. Front Door routes
# ---------------------------------------------------------------------------

# Same rule as configure-frontdoor.sh: the literal prefix in front of the
# wildcard is what Front Door compares, and the longer one wins.
route_pattern_specificity() {
  local pattern="${1:-}"
  local prefix="${pattern%%\**}"
  printf '%s' "${#prefix}"
}

# check_route <route name> <expected pattern> <expected origin group> <label>
check_route() {
  local name="${1:?}" pattern="${2:?}" group="${3:?}" label="${4:?}"
  local route patterns origin_group

  route="$(azval afd route show \
    --route-name "$name" --endpoint-name "$AFD_ENDPOINT_NAME" \
    --profile-name "$AFD_PROFILE_NAME" --resource-group "$SHARED_RESOURCE_GROUP" \
    --output json 2>/dev/null || true)"

  if [ -z "$route" ]; then
    fail "${label} route ${name} does not exist on endpoint ${AFD_ENDPOINT_NAME}"
    return 0
  fi

  patterns="$(printf '%s' "$route" | jq -r '(.patternsToMatch // []) | join(",")')"
  case ",${patterns}," in
    *",${pattern},"*) pass "${label} route ${name} matches ${pattern}" ;;
    *) fail "${label} route ${name} matches '${patterns}', expected '${pattern}'" ;;
  esac

  origin_group="$(printf '%s' "$route" | jq -r '(.originGroup.id // "") | split("/") | last')"
  if [ "$(lowercase "$origin_group")" = "$(lowercase "$group")" ]; then
    pass "${label} route ${name} points at origin group ${group}"
  else
    fail "${label} route ${name} points at origin group '${origin_group}', expected '${group}'"
  fi
}

check_frontdoor_routes() {
  local backend_specificity frontend_specificity health_specificity

  check_route "$AFD_BACKEND_ROUTE_NAME" "$AFD_BACKEND_ROUTE_PATTERN" \
    "$AFD_BACKEND_ORIGIN_GROUP_NAME" backend
  check_route "$AFD_HEALTH_ROUTE_NAME" "$AFD_HEALTH_ROUTE_PATTERN" \
    "$AFD_BACKEND_ORIGIN_GROUP_NAME" health
  check_route "$AFD_FRONTEND_ROUTE_NAME" "$AFD_FRONTEND_ROUTE_PATTERN" \
    "$AFD_FRONTEND_ORIGIN_GROUP_NAME" frontend

  # Front Door routes have no priority field; precedence comes from the path
  # pattern. This is the assertion that /api/* actually beats /*.
  backend_specificity="$(route_pattern_specificity "$AFD_BACKEND_ROUTE_PATTERN")"
  health_specificity="$(route_pattern_specificity "$AFD_HEALTH_ROUTE_PATTERN")"
  frontend_specificity="$(route_pattern_specificity "$AFD_FRONTEND_ROUTE_PATTERN")"
  if [ "$backend_specificity" -gt "$frontend_specificity" ] &&
    [ "$health_specificity" -gt "$frontend_specificity" ]; then
    pass "route precedence: '${AFD_BACKEND_ROUTE_PATTERN}' (${backend_specificity}) and '${AFD_HEALTH_ROUTE_PATTERN}' (${health_specificity}) outrank '${AFD_FRONTEND_ROUTE_PATTERN}' (${frontend_specificity})"
  else
    fail "route precedence: the backend patterns do not outrank '${AFD_FRONTEND_ROUTE_PATTERN}'; API requests would be served by the SPA"
  fi
}

# The workshop's security boundary is Private Link into an internal Container
# Apps environment, and no WAF policy is expected. A policy appearing here is
# not automatically wrong, but it is a change nobody in this repository made.
check_no_waf_policy() {
  local policies

  policies="$(azval afd security-policy list \
    --profile-name "$AFD_PROFILE_NAME" --resource-group "$SHARED_RESOURCE_GROUP" \
    --query '[].name' --output tsv 2>/dev/null || true)"

  if [ -z "$policies" ]; then
    pass "no Front Door security (WAF) policy is attached, as designed"
  else
    warn "Front Door profile ${AFD_PROFILE_NAME} has security policies this repository did not create: $(printf '%s' "$policies" | tr '\n' ' ')"
  fi
}

# ---------------------------------------------------------------------------
# 5. Private Link
# ---------------------------------------------------------------------------

check_private_link_connections() {
  local connections approved pending rejected

  connections="$(azval network private-endpoint-connection list \
    --name "$ACA_ENVIRONMENT_NAME" --resource-group "$RESOURCE_GROUP" \
    --type Microsoft.App/managedEnvironments \
    --output json 2>/dev/null || true)"

  if [ -z "$connections" ]; then
    fail "private link: could not list the private endpoint connections of ${ACA_ENVIRONMENT_NAME}"
    return 0
  fi

  approved="$(printf '%s' "$connections" | jq '[ .[]? | select((.properties.privateLinkServiceConnectionState.status // "") == "Approved") ] | length')"
  pending="$(printf '%s' "$connections" | jq '[ .[]? | select((.properties.privateLinkServiceConnectionState.status // "") == "Pending") ] | length')"
  rejected="$(printf '%s' "$connections" | jq '[ .[]? | select((.properties.privateLinkServiceConnectionState.status // "") == "Rejected") ] | length')"

  if [ "$approved" -ge 1 ]; then
    pass "private link: ${approved} approved connection(s) into ${ACA_ENVIRONMENT_NAME}"
  else
    fail "private link: no approved connection into ${ACA_ENVIRONMENT_NAME}; Front Door cannot reach the apps"
  fi
  if [ "$pending" -gt 0 ]; then
    warn "private link: ${pending} connection(s) are still pending approval"
  fi
  if [ "$rejected" -gt 0 ]; then
    warn "private link: ${rejected} connection(s) were rejected"
  fi
}

# ---------------------------------------------------------------------------
# 6. The endpoint itself
# ---------------------------------------------------------------------------

check_endpoint_responses() {
  local status content_type

  if [ -z "$AFD_ENDPOINT_HOSTNAME" ]; then
    fail "endpoint: the Front Door hostname could not be read"
    return 0
  fi

  if ! command -v curl >/dev/null 2>&1; then
    warn "endpoint: curl is not installed; skipping the live HTTP checks"
    return 0
  fi

  status="$(curl --silent --show-error --location --max-time 30 \
    --output /dev/null --write-out '%{http_code}' \
    "https://${AFD_ENDPOINT_HOSTNAME}${VERIFY_HEALTH_PATH}" 2>/dev/null || true)"
  if [ "$status" = "200" ]; then
    pass "endpoint: https://${AFD_ENDPOINT_HOSTNAME}${VERIFY_HEALTH_PATH} answered 200"
  else
    fail "endpoint: https://${AFD_ENDPOINT_HOSTNAME}${VERIFY_HEALTH_PATH} answered '${status:-no response}', expected 200"
  fi

  status="$(curl --silent --show-error --location --max-time 30 \
    --output /dev/null --write-out '%{http_code}' \
    "https://${AFD_ENDPOINT_HOSTNAME}/" 2>/dev/null || true)"
  content_type="$(curl --silent --show-error --location --max-time 30 \
    --output /dev/null --write-out '%{content_type}' \
    "https://${AFD_ENDPOINT_HOSTNAME}/" 2>/dev/null || true)"
  if [ "$status" = "200" ]; then
    case "$content_type" in
      text/html*) pass "endpoint: the SPA is served from https://${AFD_ENDPOINT_HOSTNAME}/" ;;
      *) fail "endpoint: / answered 200 but returned '${content_type:-unknown}' instead of HTML; the /* route may be pointing at the backend" ;;
    esac
  else
    fail "endpoint: https://${AFD_ENDPOINT_HOSTNAME}/ answered '${status:-no response}', expected 200"
  fi
}

# ---------------------------------------------------------------------------
# 7. Diagnostics
# ---------------------------------------------------------------------------

# check_diagnostic_setting <resource id> <setting name> <label>
check_diagnostic_setting() {
  local resource_id="${1:-}" setting_name="${2:?}" label="${3:?}"
  local workspace

  if [ -z "$resource_id" ]; then
    fail "diagnostics: ${label} was not found, so its diagnostic setting cannot be checked"
    return 0
  fi

  workspace="$(azval monitor diagnostic-settings show \
    --name "$setting_name" --resource "$resource_id" \
    --query workspaceId --output tsv 2>/dev/null || true)"

  if [ -n "$workspace" ]; then
    pass "diagnostics: ${label} sends '${setting_name}' to ${workspace##*/}"
  else
    fail "diagnostics: ${label} has no diagnostic setting named '${setting_name}'"
  fi
}

check_diagnostics() {
  check_diagnostic_setting "$ACA_ENVIRONMENT_ID" \
    "${DIAGNOSTIC_SETTING_NAME:-cost-copilot-diagnostics}" "the Container Apps environment"
  check_diagnostic_setting "$AFD_PROFILE_ID" \
    "cost-copilot-afd-${APP_ENVIRONMENT}" "the Front Door profile"
}

# ---------------------------------------------------------------------------
# 8. Fresh telemetry
# ---------------------------------------------------------------------------

# A deployment can be green on every control-plane check and still be a
# container that never serves a request, so the last check asks Application
# Insights whether anything actually happened.
check_fresh_telemetry() {
  local result count

  if [ -z "$APP_INSIGHTS_ID" ]; then
    fail "telemetry: Application Insights component ${APP_INSIGHTS_NAME} was not found"
    return 0
  fi

  result="$(azval monitor app-insights query \
    --app "$APP_INSIGHTS_ID" \
    --analytics-query "requests | where timestamp > ago(${VERIFY_TELEMETRY_WINDOW_MINUTES}m) | count" \
    --output json 2>/dev/null || true)"

  if [ -z "$result" ]; then
    fail "telemetry: the Application Insights query failed; freshness is unknown"
    return 0
  fi

  count="$(printf '%s' "$result" | jq -r '(.tables[0].rows[0][0] // 0) | tostring')"
  if [ "${count:-0}" -gt 0 ] 2>/dev/null; then
    pass "telemetry: ${count} request(s) reached Application Insights in the last ${VERIFY_TELEMETRY_WINDOW_MINUTES} minutes"
  else
    fail "telemetry: no request reached Application Insights in the last ${VERIFY_TELEMETRY_WINDOW_MINUTES} minutes"
  fi
}

# ---------------------------------------------------------------------------

main() {
  parse_arguments "$@"
  log "verifying the ${TARGET_ENVIRONMENT} environment (read-only)"
  require_cmd az jq || die "install the missing command-line tools and re-run"
  load_environment_config
  require_azure_context
  resolve_dependencies

  check_runtime_identities
  check_least_privilege
  check_running_images
  check_frontdoor_routes
  check_no_waf_policy
  check_private_link_connections
  check_endpoint_responses
  check_diagnostics
  check_fresh_telemetry

  if [ "$FAILURES" -gt 0 ]; then
    die "${FAILURES} of ${CHECKS} checks failed for ${TARGET_ENVIRONMENT}"
  fi
  ok "all ${CHECKS} checks passed for ${TARGET_ENVIRONMENT}"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
