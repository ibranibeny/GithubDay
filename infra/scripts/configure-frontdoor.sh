#!/usr/bin/env bash
#
# configure-frontdoor.sh - point the shared Azure Front Door Premium profile at
# one environment's internal Container Apps, and wire up the alerts and
# diagnostics that watch it.
#
#   bash infra/scripts/configure-frontdoor.sh staging
#   bash infra/scripts/configure-frontdoor.sh production
#   DRY_RUN=1 bash infra/scripts/configure-frontdoor.sh staging
#
# Per environment this creates, on the shared profile:
#
#   frontend origin group + health probe  ->  frontend origin (private link)
#   backend  origin group + health probe  ->  backend  origin (private link)
#   route  /api/*     -> backend origin group
#   route  /health/*  -> backend origin group
#   route  /*         -> frontend origin group
#
# The backend mounts its API under /api and its probes under /health, so both
# prefixes have to reach the backend origin; without the /health route the
# catch-all would hand /health/live to the SPA.
#
# Route precedence: Azure Front Door Standard/Premium routes have NO priority
# field. Front Door always matches the MOST SPECIFIC path pattern, so the
# literal prefixes '/api/' and '/health/' beat the catch-all '/'. The patterns
# are kept unambiguous (each backend pattern is a strict extension of the
# catch-all) so that ordering is decided by the service, not by creation order.
# See assert_route_patterns_are_ordered.
#
# Security boundary: the Container Apps environments are internal-only with
# public network access disabled, so Private Link IS the perimeter. This
# workshop deliberately attaches NO WAF / security policy - grep this file for
# 'waf' and 'security-policy' and you will find nothing but this comment.
#
# Private-link approval is deliberately narrow: only a PENDING connection whose
# description matches the exact per-environment, per-role request message this
# script sends is approved. Every other pending request on the managed
# environment is reported and left alone.
#
# stdout is a single JSON object; every log line goes to stderr.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
. "${SCRIPT_DIR}/lib.sh"

INFRA_CONFIG_DIR="${INFRA_CONFIG_DIR:-${SCRIPT_DIR}/../config}"

TARGET_ENVIRONMENT=""
AFD_PROFILE_ID=""
AFD_ENDPOINT_ID=""
AFD_ENDPOINT_HOSTNAME=""
ACA_ENVIRONMENT_ID=""
LOG_ANALYTICS_ID=""
APP_INSIGHTS_ID=""
BACKEND_APP_ID=""
BACKEND_APP_FQDN=""
FRONTEND_APP_ID=""
FRONTEND_APP_FQDN=""
ACTION_GROUP_ID=""
APPROVED_PRIVATE_LINK_CONNECTIONS=0

declare -a ENVIRONMENT_TAGS=()

trap cleanup_temp_files EXIT

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

parse_environment_argument() {
  local candidate="${1:-}"
  case "$candidate" in
    staging | production) TARGET_ENVIRONMENT="$candidate" ;;
    '') die "usage: configure-frontdoor.sh <staging|production>" ;;
    *) die "unknown environment '${candidate}'; expected 'staging' or 'production'" ;;
  esac
}

load_environment_config() {
  load_config "${INFRA_CONFIG_DIR}/${TARGET_ENVIRONMENT}.env"
  load_config "${INFRA_CONFIG_DIR}/shared.env"

  require_env \
    AZURE_SUBSCRIPTION_ID AZURE_TENANT_ID ACA_LOCATION APP_ENVIRONMENT \
    RESOURCE_GROUP SHARED_RESOURCE_GROUP \
    AFD_PROFILE_NAME AFD_ENDPOINT_NAME \
    AFD_FRONTEND_ORIGIN_GROUP_NAME AFD_BACKEND_ORIGIN_GROUP_NAME \
    AFD_FRONTEND_ORIGIN_NAME AFD_BACKEND_ORIGIN_NAME \
    AFD_FRONTEND_ROUTE_NAME AFD_BACKEND_ROUTE_NAME AFD_HEALTH_ROUTE_NAME \
    AFD_FRONTEND_ROUTE_PATTERN AFD_BACKEND_ROUTE_PATTERN AFD_HEALTH_ROUTE_PATTERN \
    AFD_FRONTEND_PROBE_PATH AFD_BACKEND_PROBE_PATH \
    AFD_PROBE_PROTOCOL AFD_PROBE_INTERVAL_SECONDS \
    AFD_FORWARDING_PROTOCOL AFD_PRIVATE_LINK_REQUEST_PREFIX \
    ACA_ENVIRONMENT_NAME BACKEND_APP_NAME FRONTEND_APP_NAME \
    LOG_ANALYTICS_NAME APP_INSIGHTS_NAME \
    ALERT_ACTION_GROUP_NAME ALERT_SEVERITY \
    ALERT_5XX_THRESHOLD ALERT_P95_DURATION_MS \
    ALERT_FAILED_DEPENDENCY_THRESHOLD ALERT_RESTART_COUNT_THRESHOLD \
    ALERT_WINDOW ALERT_EVALUATION_FREQUENCY ALERT_NO_TELEMETRY_WINDOW \
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

  assert_route_patterns_are_ordered
}

# Front Door picks the most specific path pattern. That only gives a
# deterministic answer when one pattern is a strict prefix of the other, so the
# configuration is checked here instead of trusting the two .env files.
assert_route_patterns_are_ordered() {
  local frontend="$AFD_FRONTEND_ROUTE_PATTERN" pattern

  [ "$frontend" = "/*" ] ||
    die "AFD_FRONTEND_ROUTE_PATTERN must be the catch-all '/*', not '${frontend}'"

  for pattern in "$AFD_BACKEND_ROUTE_PATTERN" "$AFD_HEALTH_ROUTE_PATTERN"; do
    case "$pattern" in
      /*/\*) : ;;
      *) die "backend route patterns must look like '/api/*', not '${pattern}'" ;;
    esac
    if [ "$(route_pattern_specificity "$pattern")" -le "$(route_pattern_specificity "$frontend")" ]; then
      die "'${pattern}' is not more specific than '${frontend}'; Front Door would send those requests to the SPA"
    fi
  done

  if [ "$AFD_BACKEND_ROUTE_PATTERN" = "$AFD_HEALTH_ROUTE_PATTERN" ]; then
    die "the API and health route patterns are identical ('${AFD_BACKEND_ROUTE_PATTERN}')"
  fi

  ok "route precedence: '${AFD_BACKEND_ROUTE_PATTERN}' and '${AFD_HEALTH_ROUTE_PATTERN}' are both more specific than '${frontend}'"
}

# route_pattern_specificity <pattern> - length of the literal path prefix in
# front of the wildcard. '/api/*' scores 5 and '/*' scores 1, which is the same
# ordering Front Door applies when it picks the most specific match. verify.sh
# reimplements this so the two agree without sourcing each other.
route_pattern_specificity() {
  local pattern="${1:-}"
  local prefix="${pattern%%\**}"
  printf '%s' "${#prefix}"
}

# The description Front Door stamps on the private endpoint connection request.
# It carries the environment and the role so the approval step can single out
# exactly one request instead of approving whatever is pending.
private_link_request_message() {
  printf '%s %s %s' "$AFD_PRIVATE_LINK_REQUEST_PREFIX" "$APP_ENVIRONMENT" "${1:?private_link_request_message requires a role}"
}

# ---------------------------------------------------------------------------
# Existing resources this script depends on
# ---------------------------------------------------------------------------

resolve_dependencies() {
  AFD_PROFILE_ID="$(azval afd profile show \
    --profile-name "$AFD_PROFILE_NAME" --resource-group "$SHARED_RESOURCE_GROUP" \
    --query id --output tsv 2>/dev/null || true)"
  [ -n "$AFD_PROFILE_ID" ] ||
    die "Front Door profile ${AFD_PROFILE_NAME} was not found in ${SHARED_RESOURCE_GROUP}; run provision-shared.sh first"

  AFD_ENDPOINT_ID="$(azval afd endpoint show \
    --endpoint-name "$AFD_ENDPOINT_NAME" --profile-name "$AFD_PROFILE_NAME" \
    --resource-group "$SHARED_RESOURCE_GROUP" \
    --query id --output tsv 2>/dev/null || true)"
  [ -n "$AFD_ENDPOINT_ID" ] ||
    die "Front Door endpoint ${AFD_ENDPOINT_NAME} was not found; run provision-shared.sh first"

  AFD_ENDPOINT_HOSTNAME="$(azval afd endpoint show \
    --endpoint-name "$AFD_ENDPOINT_NAME" --profile-name "$AFD_PROFILE_NAME" \
    --resource-group "$SHARED_RESOURCE_GROUP" \
    --query hostName --output tsv 2>/dev/null || true)"

  ACA_ENVIRONMENT_ID="$(azval containerapp env show \
    --name "$ACA_ENVIRONMENT_NAME" --resource-group "$RESOURCE_GROUP" \
    --query id --output tsv 2>/dev/null || true)"
  [ -n "$ACA_ENVIRONMENT_ID" ] ||
    die "Container Apps environment ${ACA_ENVIRONMENT_NAME} was not found in ${RESOURCE_GROUP}; run provision-environment.sh first"

  LOG_ANALYTICS_ID="$(azval monitor log-analytics workspace show \
    --workspace-name "$LOG_ANALYTICS_NAME" --resource-group "$RESOURCE_GROUP" \
    --query id --output tsv 2>/dev/null || true)"
  [ -n "$LOG_ANALYTICS_ID" ] ||
    die "Log Analytics workspace ${LOG_ANALYTICS_NAME} was not found in ${RESOURCE_GROUP}"

  APP_INSIGHTS_ID="$(azval monitor app-insights component show \
    --app "$APP_INSIGHTS_NAME" --resource-group "$RESOURCE_GROUP" \
    --query id --output tsv 2>/dev/null || true)"
  [ -n "$APP_INSIGHTS_ID" ] ||
    die "Application Insights component ${APP_INSIGHTS_NAME} was not found in ${RESOURCE_GROUP}"

  resolve_container_app "$BACKEND_APP_NAME"
  BACKEND_APP_ID="$CONTAINER_APP_ID"
  BACKEND_APP_FQDN="$CONTAINER_APP_FQDN"

  resolve_container_app "$FRONTEND_APP_NAME"
  FRONTEND_APP_ID="$CONTAINER_APP_ID"
  FRONTEND_APP_FQDN="$CONTAINER_APP_FQDN"
}

# resolve_container_app <name> - sets CONTAINER_APP_ID and CONTAINER_APP_FQDN.
# The FQDN of an internal ingress looks like
# <app>.internal.<suffix>.<region>.azurecontainerapps.io and is what the
# private-link origin has to send as its host name and host header.
CONTAINER_APP_ID=""
CONTAINER_APP_FQDN=""
resolve_container_app() {
  local name="${1:?resolve_container_app requires an app name}"

  CONTAINER_APP_ID="$(azval containerapp show \
    --name "$name" --resource-group "$RESOURCE_GROUP" \
    --query id --output tsv 2>/dev/null || true)"
  [ -n "$CONTAINER_APP_ID" ] ||
    die "container app ${name} was not found in ${RESOURCE_GROUP}; run provision-environment.sh first"

  CONTAINER_APP_FQDN="$(azval containerapp show \
    --name "$name" --resource-group "$RESOURCE_GROUP" \
    --query 'properties.configuration.ingress.fqdn' --output tsv 2>/dev/null || true)"
  [ -n "$CONTAINER_APP_FQDN" ] ||
    die "container app ${name} has no ingress FQDN; Front Door cannot reach it"

  case "$CONTAINER_APP_FQDN" in
    *.internal.*) : ;;
    *) warn "container app ${name} resolves to ${CONTAINER_APP_FQDN}, which does not look like an internal ingress FQDN" ;;
  esac
}

# ---------------------------------------------------------------------------
# Origin groups and origins
# ---------------------------------------------------------------------------

# ensure_origin_group <name> <probe path>
ensure_origin_group() {
  local name="${1:?ensure_origin_group requires a name}"
  local probe_path="${2:?ensure_origin_group requires a probe path}"
  local existing

  existing="$(azval afd origin-group show \
    --origin-group-name "$name" --profile-name "$AFD_PROFILE_NAME" \
    --resource-group "$SHARED_RESOURCE_GROUP" \
    --query id --output tsv 2>/dev/null || true)"

  if [ -n "$existing" ]; then
    ok "Front Door origin group ${name} already exists"
    return 0
  fi

  log "creating Front Door origin group ${name} (probe ${AFD_PROBE_PROTOCOL} ${probe_path})"
  az_do afd origin-group create \
    --origin-group-name "$name" \
    --profile-name "$AFD_PROFILE_NAME" \
    --resource-group "$SHARED_RESOURCE_GROUP" \
    --probe-request-type GET \
    --probe-protocol "$AFD_PROBE_PROTOCOL" \
    --probe-path "$probe_path" \
    --probe-interval-in-seconds "$AFD_PROBE_INTERVAL_SECONDS" \
    --sample-size 4 \
    --successful-samples-required 3 \
    --additional-latency-in-milliseconds 50 \
    --output none >/dev/null ||
    die "could not create the Front Door origin group ${name}"
}

# True when the installed `az afd origin create` exposes the explicit
# --enable-private-link family of flags. Older and newer builds of the
# front-door command module disagree: some take --enable-private-link /
# --private-link-resource, others only take the --shared-private-link-resource
# compound argument. The answer is cached because `--help` is not cheap.
AFD_PRIVATE_LINK_FLAG_STYLE=""
detect_private_link_flag_style() {
  local help_text
  if [ -n "$AFD_PRIVATE_LINK_FLAG_STYLE" ]; then
    return 0
  fi
  help_text="$(azval afd origin create --help 2>/dev/null || true)"
  case "$help_text" in
    *--enable-private-link*) AFD_PRIVATE_LINK_FLAG_STYLE="explicit" ;;
    *--shared-private-link-resource*) AFD_PRIVATE_LINK_FLAG_STYLE="shared" ;;
    *)
      warn "could not read the flags of 'az afd origin create'; assuming --enable-private-link"
      AFD_PRIVATE_LINK_FLAG_STYLE="explicit"
      ;;
  esac
  log "private-link origin flag style: ${AFD_PRIVATE_LINK_FLAG_STYLE}"
}

# ensure_private_origin <origin name> <origin group name> <app fqdn> <role>
ensure_private_origin() {
  local name="${1:?ensure_private_origin requires an origin name}"
  local group="${2:?ensure_private_origin requires an origin group name}"
  local fqdn="${3:?ensure_private_origin requires an origin host name}"
  local role="${4:?ensure_private_origin requires a role}"
  local existing request_message
  local -a private_link_args=()

  existing="$(azval afd origin show \
    --origin-name "$name" --origin-group-name "$group" \
    --profile-name "$AFD_PROFILE_NAME" --resource-group "$SHARED_RESOURCE_GROUP" \
    --query id --output tsv 2>/dev/null || true)"

  if [ -n "$existing" ]; then
    # Re-creating a private origin would raise a second private endpoint
    # connection request on the managed environment, so an existing origin is
    # never touched here.
    ok "Front Door origin ${name} already exists"
    return 0
  fi

  detect_private_link_flag_style
  request_message="$(private_link_request_message "$role")"

  if [ "$AFD_PRIVATE_LINK_FLAG_STYLE" = "shared" ]; then
    warn "this Azure CLI only offers --shared-private-link-resource; the compound argument shape is not verified against a live deployment"
    private_link_args=(
      --shared-private-link-resource
      "{private-link:{id:${ACA_ENVIRONMENT_ID}},private-link-location:${ACA_LOCATION},group-id:managedEnvironments,request-message:'${request_message}'}"
    )
  else
    private_link_args=(
      --enable-private-link true
      --private-link-resource "$ACA_ENVIRONMENT_ID"
      --private-link-location "$ACA_LOCATION"
      --private-link-sub-resource-type managedEnvironments
      --private-link-request-message "$request_message"
    )
  fi

  log "creating private-link Front Door origin ${name} -> ${fqdn}"
  az_do afd origin create \
    --origin-name "$name" \
    --origin-group-name "$group" \
    --profile-name "$AFD_PROFILE_NAME" \
    --resource-group "$SHARED_RESOURCE_GROUP" \
    --host-name "$fqdn" \
    --origin-host-header "$fqdn" \
    --http-port 80 \
    --https-port 443 \
    --priority 1 \
    --weight 1000 \
    --enabled-state Enabled \
    "${private_link_args[@]}" \
    --output none >/dev/null ||
    die "could not create the private-link origin ${name}; if this Azure CLI rejected the private-link flags, run 'az extension update --name front-door' and retry"
}

ensure_origins() {
  ensure_origin_group "$AFD_FRONTEND_ORIGIN_GROUP_NAME" "$AFD_FRONTEND_PROBE_PATH"
  ensure_origin_group "$AFD_BACKEND_ORIGIN_GROUP_NAME" "$AFD_BACKEND_PROBE_PATH"

  ensure_private_origin "$AFD_FRONTEND_ORIGIN_NAME" "$AFD_FRONTEND_ORIGIN_GROUP_NAME" \
    "$FRONTEND_APP_FQDN" frontend
  ensure_private_origin "$AFD_BACKEND_ORIGIN_NAME" "$AFD_BACKEND_ORIGIN_GROUP_NAME" \
    "$BACKEND_APP_FQDN" backend
}

# ---------------------------------------------------------------------------
# Private endpoint connection approval
# ---------------------------------------------------------------------------

# Approve only the PENDING connection request whose description equals the
# message this script sent for this environment and role. Front Door does not
# publish its profile id on the connection, so the request message is the
# discriminator - which is exactly why it carries the environment and the role.
#
# Anything else that is pending on the managed environment is reported and left
# untouched: blanket-approving would let an unrelated Front Door profile, or
# somebody else's private endpoint, into an environment whose only perimeter is
# this private link.
approve_matching_private_link_connections() {
  local connections role expected pending_ids id total_pending unmatched

  connections="$(azval network private-endpoint-connection list \
    --name "$ACA_ENVIRONMENT_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --type Microsoft.App/managedEnvironments \
    --output json 2>/dev/null || true)"

  if [ -z "$connections" ]; then
    warn "could not list the private endpoint connections of ${ACA_ENVIRONMENT_NAME}; approve them by hand"
    return 0
  fi

  total_pending="$(printf '%s' "$connections" | jq '
    [ .[]? | select((.properties.privateLinkServiceConnectionState.status // "") == "Pending") ] | length')"

  for role in frontend backend; do
    expected="$(private_link_request_message "$role")"
    pending_ids="$(printf '%s' "$connections" | jq -r --arg want "$expected" '
      .[]?
      | select((.properties.privateLinkServiceConnectionState.status // "") == "Pending")
      | select((.properties.privateLinkServiceConnectionState.description // "") == $want)
      | .id')"

    if [ -z "$pending_ids" ]; then
      log "no pending private endpoint connection matches '${expected}'"
      continue
    fi

    while IFS= read -r id; do
      [ -n "$id" ] || continue
      log "approving the private endpoint connection requested as '${expected}'"
      az_do network private-endpoint-connection approve \
        --id "$id" \
        --description "approved by configure-frontdoor.sh for ${APP_ENVIRONMENT}" \
        --output none >/dev/null ||
        die "could not approve the private endpoint connection ${id}"
      APPROVED_PRIVATE_LINK_CONNECTIONS=$((APPROVED_PRIVATE_LINK_CONNECTIONS + 1))
    done <<<"$pending_ids"
  done

  unmatched=$((total_pending - APPROVED_PRIVATE_LINK_CONNECTIONS))
  if [ "$unmatched" -gt 0 ]; then
    warn "${unmatched} pending private endpoint connection(s) on ${ACA_ENVIRONMENT_NAME} do not match this environment's request message and were left pending; review them by hand"
  fi
}

# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

# ensure_route <route name> <origin group name> <pattern>
ensure_route() {
  local name="${1:?ensure_route requires a route name}"
  local group="${2:?ensure_route requires an origin group name}"
  local pattern="${3:?ensure_route requires a path pattern}"
  local existing

  existing="$(azval afd route show \
    --route-name "$name" --endpoint-name "$AFD_ENDPOINT_NAME" \
    --profile-name "$AFD_PROFILE_NAME" --resource-group "$SHARED_RESOURCE_GROUP" \
    --query id --output tsv 2>/dev/null || true)"

  if [ -n "$existing" ]; then
    ok "Front Door route ${name} (${pattern}) already exists"
    return 0
  fi

  log "creating Front Door route ${name} for ${pattern} -> ${group} (specificity $(route_pattern_specificity "$pattern"))"
  az_do afd route create \
    --route-name "$name" \
    --endpoint-name "$AFD_ENDPOINT_NAME" \
    --profile-name "$AFD_PROFILE_NAME" \
    --resource-group "$SHARED_RESOURCE_GROUP" \
    --origin-group "$group" \
    --patterns-to-match "$pattern" \
    --supported-protocols Http Https \
    --forwarding-protocol "$AFD_FORWARDING_PROTOCOL" \
    --https-redirect Enabled \
    --link-to-default-domain Enabled \
    --enabled-state Enabled \
    --output none >/dev/null ||
    die "could not create the Front Door route ${name}"
}

ensure_routes() {
  # The backend routes are created first so that, on a fresh profile, /api/* is
  # already resolvable the moment /* starts serving the SPA. Creation order does
  # not decide precedence - the path pattern does - but it removes a window in
  # which the SPA is live and its API is not.
  ensure_route "$AFD_BACKEND_ROUTE_NAME" "$AFD_BACKEND_ORIGIN_GROUP_NAME" "$AFD_BACKEND_ROUTE_PATTERN"
  ensure_route "$AFD_HEALTH_ROUTE_NAME" "$AFD_BACKEND_ORIGIN_GROUP_NAME" "$AFD_HEALTH_ROUTE_PATTERN"
  ensure_route "$AFD_FRONTEND_ROUTE_NAME" "$AFD_FRONTEND_ORIGIN_GROUP_NAME" "$AFD_FRONTEND_ROUTE_PATTERN"
}

# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------

# Front Door is a global resource with one set of diagnostic categories, but a
# diagnostic setting is identified by name, so each environment gets its own
# setting pointing at its own workspace. Two settings with different names and
# different destinations coexist happily, which is how both workspaces end up
# with the access and health-probe logs.
ensure_frontdoor_diagnostics() {
  local setting_name categories logs metrics existing logs_file metrics_file
  local -a args=()

  setting_name="cost-copilot-afd-${APP_ENVIRONMENT}"

  categories="$(azval monitor diagnostic-settings categories list \
    --resource "$AFD_PROFILE_ID" --output json 2>/dev/null || true)"
  if [ -z "$categories" ]; then
    warn "no diagnostic categories are published for ${AFD_PROFILE_NAME}; skipping its diagnostic setting"
    return 0
  fi

  # FrontDoorAccessLog and FrontDoorHealthProbeLog are the two this workshop
  # needs; anything else the platform publishes is left off to keep the
  # workspace inside the free tier.
  logs="$(printf '%s' "$categories" |
    jq -c '(if type == "array" then . else (.value // []) end)
           | [ .[] | select(.categoryType == "Logs")
                   | select(.name | test("Access|HealthProbe"))
                   | { category: .name, enabled: true } ]')"
  metrics="$(printf '%s' "$categories" |
    jq -c '(if type == "array" then . else (.value // []) end)
           | [ .[] | select(.categoryType == "Metrics") | { category: .name, enabled: true } ]')"

  if [ "$logs" = "[]" ] && [ "$metrics" = "[]" ]; then
    warn "${AFD_PROFILE_NAME} publishes no access or health-probe log category; skipping its diagnostic setting"
    return 0
  fi

  existing="$(azval monitor diagnostic-settings show \
    --name "$setting_name" --resource "$AFD_PROFILE_ID" \
    --query workspaceId --output tsv 2>/dev/null || true)"
  if [ "$(lowercase "$existing")" = "$(lowercase "$LOG_ANALYTICS_ID")" ]; then
    ok "Front Door diagnostic setting ${setting_name} already targets ${LOG_ANALYTICS_NAME}"
    return 0
  fi

  if [ "$logs" != "[]" ]; then
    az_body_file "$logs" || die "could not stage the Front Door diagnostic log categories"
    logs_file="$AZ_BODY_FILE"
    args+=(--logs "@${logs_file}")
  fi
  if [ "$metrics" != "[]" ]; then
    az_body_file "$metrics" || die "could not stage the Front Door diagnostic metric categories"
    metrics_file="$AZ_BODY_FILE"
    args+=(--metrics "@${metrics_file}")
  fi

  log "sending Front Door access and health-probe logs to ${LOG_ANALYTICS_NAME}"
  az_do monitor diagnostic-settings create \
    --name "$setting_name" \
    --resource "$AFD_PROFILE_ID" \
    --workspace "$LOG_ANALYTICS_ID" \
    "${args[@]}" --output none >/dev/null ||
    die "could not create the Front Door diagnostic setting ${setting_name}"
}

# ---------------------------------------------------------------------------
# Alerts
# ---------------------------------------------------------------------------

# The action group only carries an email receiver when ALERT_EMAIL is set. An
# alert rule with no action still fires and still shows up in Azure Monitor, so
# an unset ALERT_EMAIL degrades the notification, not the detection.
ensure_action_group() {
  local existing

  existing="$(azval monitor action-group show \
    --name "$ALERT_ACTION_GROUP_NAME" --resource-group "$RESOURCE_GROUP" \
    --query id --output tsv 2>/dev/null || true)"

  if [ -n "$existing" ]; then
    ACTION_GROUP_ID="$existing"
    ok "action group ${ALERT_ACTION_GROUP_NAME} already exists"
    return 0
  fi

  if [ -z "${ALERT_EMAIL:-}" ]; then
    warn "ALERT_EMAIL is not set; creating the action group without a receiver (alerts fire but notify nobody)"
    ACTION_GROUP_ID="$(az_do monitor action-group create \
      --name "$ALERT_ACTION_GROUP_NAME" \
      --resource-group "$RESOURCE_GROUP" \
      --short-name "costcop" \
      --query id --output tsv)"
    return 0
  fi

  log "creating action group ${ALERT_ACTION_GROUP_NAME} with an email receiver"
  ACTION_GROUP_ID="$(az_do monitor action-group create \
    --name "$ALERT_ACTION_GROUP_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --short-name "costcop" \
    --action email oncall "$ALERT_EMAIL" \
    --query id --output tsv)"
}

# ensure_metric_alert <name> <scope> <condition> <description>
#
# `az monitor metrics alert create` is create-only in practice, so an existing
# rule is left alone rather than rewritten. That keeps a threshold somebody
# tuned in the portal from being reset on every run.
ensure_metric_alert() {
  local name="${1:?ensure_metric_alert requires a name}"
  local scope="${2:?ensure_metric_alert requires a scope}"
  local condition="${3:?ensure_metric_alert requires a condition}"
  local description="${4:-}"
  local existing
  local -a args=()

  existing="$(azval monitor metrics alert show \
    --name "$name" --resource-group "$RESOURCE_GROUP" \
    --query id --output tsv 2>/dev/null || true)"
  if [ -n "$existing" ]; then
    ok "metric alert ${name} already exists"
    return 0
  fi

  if [ -n "$ACTION_GROUP_ID" ]; then
    args+=(--action "$ACTION_GROUP_ID")
  fi

  log "creating metric alert ${name}"
  az_do monitor metrics alert create \
    --name "$name" \
    --resource-group "$RESOURCE_GROUP" \
    --scopes "$scope" \
    --condition "$condition" \
    --window-size "$ALERT_WINDOW" \
    --evaluation-frequency "$ALERT_EVALUATION_FREQUENCY" \
    --severity "$ALERT_SEVERITY" \
    --description "$description" \
    "${args[@]}" --output none >/dev/null ||
    die "could not create the metric alert ${name}"
}

# ensure_query_alert <name> <scope> <condition> <placeholder> <kql> <window> <description>
#
# Percentiles and "nothing arrived at all" cannot be expressed as platform
# metric alerts, so those two live as scheduled query rules over the
# Application Insights workspace data.
ensure_query_alert() {
  local name="${1:?ensure_query_alert requires a name}"
  local scope="${2:?ensure_query_alert requires a scope}"
  local condition="${3:?ensure_query_alert requires a condition}"
  local placeholder="${4:?ensure_query_alert requires a placeholder name}"
  local kql="${5:?ensure_query_alert requires a query}"
  local window="${6:?ensure_query_alert requires a window}"
  local description="${7:-}"
  local existing
  local -a args=()

  existing="$(azval monitor scheduled-query show \
    --name "$name" --resource-group "$RESOURCE_GROUP" \
    --query id --output tsv 2>/dev/null || true)"
  if [ -n "$existing" ]; then
    ok "scheduled query alert ${name} already exists"
    return 0
  fi

  if [ -n "$ACTION_GROUP_ID" ]; then
    args+=(--action-groups "$ACTION_GROUP_ID")
  fi

  log "creating scheduled query alert ${name}"
  az_do monitor scheduled-query create \
    --name "$name" \
    --resource-group "$RESOURCE_GROUP" \
    --scopes "$scope" \
    --condition "$condition" \
    --condition-query "${placeholder}=${kql}" \
    --window-size "$window" \
    --evaluation-frequency "$ALERT_EVALUATION_FREQUENCY" \
    --severity "$ALERT_SEVERITY" \
    --description "$description" \
    "${args[@]}" --output none >/dev/null ||
    die "could not create the scheduled query alert ${name}"
}

ensure_alerts() {
  ensure_action_group

  # 1. Backend HTTP 5xx error rate. The dimension filter keeps 4xx and healthy
  #    traffic out of the count.
  ensure_metric_alert \
    "alert-${APP_ENVIRONMENT}-backend-5xx" \
    "$BACKEND_APP_ID" \
    "total Requests > ${ALERT_5XX_THRESHOLD} where statusCodeCategory includes 5xx" \
    "Backend container app returned more than ${ALERT_5XX_THRESHOLD} 5xx responses in ${ALERT_WINDOW}."

  # 2. Replica restart count - a crash loop shows up here long before the SPA
  #    notices.
  ensure_metric_alert \
    "alert-${APP_ENVIRONMENT}-backend-restarts" \
    "$BACKEND_APP_ID" \
    "total RestartCount > ${ALERT_RESTART_COUNT_THRESHOLD}" \
    "Backend replicas restarted more than ${ALERT_RESTART_COUNT_THRESHOLD} times in ${ALERT_WINDOW}."

  # 3. Failed dependencies - the Cost Management and Foundry calls the backend
  #    makes on every question.
  ensure_metric_alert \
    "alert-${APP_ENVIRONMENT}-failed-dependencies" \
    "$APP_INSIGHTS_ID" \
    "count dependencies/failed > ${ALERT_FAILED_DEPENDENCY_THRESHOLD}" \
    "More than ${ALERT_FAILED_DEPENDENCY_THRESHOLD} dependency calls failed in ${ALERT_WINDOW}."

  # 4. P95 request duration. Metric alerts cannot aggregate a percentile, so
  #    this one is a query over the requests table.
  ensure_query_alert \
    "alert-${APP_ENVIRONMENT}-p95-duration" \
    "$APP_INSIGHTS_ID" \
    "max 'P95Duration' from 'RequestDuration' > ${ALERT_P95_DURATION_MS} at least 1 violations out of 1 aggregated points" \
    "RequestDuration" \
    "requests | summarize P95Duration = percentile(duration, 95) by bin(timestamp, 5m)" \
    "$ALERT_WINDOW" \
    "The 95th percentile request duration exceeded ${ALERT_P95_DURATION_MS} ms."

  # 5. No telemetry after a deployment. A deployment that silently produces a
  #    container which never serves a request looks healthy on every other
  #    signal, so the absence of requests is alerted on directly.
  ensure_query_alert \
    "alert-${APP_ENVIRONMENT}-no-telemetry" \
    "$APP_INSIGHTS_ID" \
    "count 'RequestCount' < 1 at least 1 violations out of 1 aggregated points" \
    "RequestCount" \
    "requests" \
    "$ALERT_NO_TELEMETRY_WINDOW" \
    "No request telemetry reached Application Insights during ${ALERT_NO_TELEMETRY_WINDOW}; the deployment may be dead."
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

emit_output() {
  jq -n \
    --arg environment "$APP_ENVIRONMENT" \
    --arg profileName "$AFD_PROFILE_NAME" \
    --arg profileId "$AFD_PROFILE_ID" \
    --arg endpointName "$AFD_ENDPOINT_NAME" \
    --arg endpointId "$AFD_ENDPOINT_ID" \
    --arg endpointHostname "$AFD_ENDPOINT_HOSTNAME" \
    --arg acaEnvironmentId "$ACA_ENVIRONMENT_ID" \
    --arg frontendOriginGroup "$AFD_FRONTEND_ORIGIN_GROUP_NAME" \
    --arg frontendOrigin "$AFD_FRONTEND_ORIGIN_NAME" \
    --arg frontendRoute "$AFD_FRONTEND_ROUTE_NAME" \
    --arg frontendPattern "$AFD_FRONTEND_ROUTE_PATTERN" \
    --arg frontendFqdn "$FRONTEND_APP_FQDN" \
    --arg backendOriginGroup "$AFD_BACKEND_ORIGIN_GROUP_NAME" \
    --arg backendOrigin "$AFD_BACKEND_ORIGIN_NAME" \
    --arg backendRoute "$AFD_BACKEND_ROUTE_NAME" \
    --arg backendPattern "$AFD_BACKEND_ROUTE_PATTERN" \
    --arg healthRoute "$AFD_HEALTH_ROUTE_NAME" \
    --arg healthPattern "$AFD_HEALTH_ROUTE_PATTERN" \
    --arg backendFqdn "$BACKEND_APP_FQDN" \
    --arg actionGroupId "$ACTION_GROUP_ID" \
    --argjson approvedConnections "$APPROVED_PRIVATE_LINK_CONNECTIONS" \
    '{
      environment: $environment,
      frontDoor: {
        profileName: $profileName,
        profileId: $profileId,
        endpointName: $endpointName,
        endpointId: $endpointId,
        endpointHostname: $endpointHostname,
        wafPolicy: null,
        routes: [
          { name: $backendRoute, pattern: $backendPattern, originGroup: $backendOriginGroup, origin: $backendOrigin, originHost: $backendFqdn },
          { name: $healthRoute, pattern: $healthPattern, originGroup: $backendOriginGroup, origin: $backendOrigin, originHost: $backendFqdn },
          { name: $frontendRoute, pattern: $frontendPattern, originGroup: $frontendOriginGroup, origin: $frontendOrigin, originHost: $frontendFqdn }
        ]
      },
      privateLink: {
        managedEnvironmentId: $acaEnvironmentId,
        subResourceType: "managedEnvironments",
        approvedConnections: $approvedConnections
      },
      monitoring: { actionGroupId: $actionGroupId }
    }'
}

# ---------------------------------------------------------------------------

main() {
  parse_environment_argument "${1:-}"
  log "configuring Front Door and monitoring for ${TARGET_ENVIRONMENT}"
  require_cmd az jq || die "install the missing command-line tools and re-run"
  load_environment_config
  require_azure_context
  ensure_az_extension front-door containerapp application-insights scheduled-query
  resolve_dependencies

  ensure_origins
  approve_matching_private_link_connections
  ensure_routes
  ensure_frontdoor_diagnostics
  ensure_alerts

  ok "Front Door and monitoring are configured for ${TARGET_ENVIRONMENT}"
  emit_output
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
