#!/usr/bin/env bats
#
# Unit tests for infra/scripts/configure-frontdoor.sh.
#
# No Azure call is ever made: `az` is replaced by a stub executable placed first
# on PATH. A PATH stub is required rather than a shell function because azval
# and az_do call `command az`, which bypasses functions and aliases but still
# honours PATH.
#
# The stub terminates every line with CRLF, exactly like the Windows az.cmd
# reached through WSL, and answers `az account show --query '[a,b,c]' -o tsv`
# with one value PER LINE - which is what the real CLI does with a JMESPath
# array. A tab-delimited row would hide the parsing bug this project already
# hit once.
#
# `jq` is NOT stubbed; the script uses it for every JSON decision.
#
# Every stub invocation is appended to $AZ_CALL_LOG, which is how the tests tell
# "created", "left alone" and "never called at all" apart.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPTS_DIR="${REPO_ROOT}/infra/scripts"
  FRONTDOOR_SCRIPT="${SCRIPTS_DIR}/configure-frontdoor.sh"

  TEST_TMPDIR="${BATS_TEST_TMPDIR:-$(mktemp -d)}"
  STUB_BIN="${TEST_TMPDIR}/bin"
  mkdir -p "${STUB_BIN}"

  AZ_CALL_LOG="${TEST_TMPDIR}/az-calls.log"
  : >"${AZ_CALL_LOG}"
  export AZ_CALL_LOG

  write_az_stub
  PATH="${STUB_BIN}:${PATH}"
  export PATH

  # Matches infra/config/shared.env so the context guard passes by default.
  export FAKE_TENANT_ID="a1571616-cb5c-4d81-93ab-83c3856d83f2"
  export FAKE_SUBSCRIPTION_ID="439cf6ec-8907-40ee-bae2-7efd9656cd09"

  # missing | equal - drives every "show" the stub answers for the resources
  # this script owns. The prerequisites (profile, endpoint, apps, workspaces)
  # always exist, because configure-frontdoor.sh refuses to run without them.
  export FAKE_STATE="missing"

  # explicit | shared - which private-link flags `az afd origin create --help`
  # advertises.
  export FAKE_PRIVATE_LINK_FLAGS="explicit"

  export FAKE_TAG_ENVIRONMENT="staging"
}

az_calls() {
  cat "${AZ_CALL_LOG}"
}

write_az_stub() {
  cat >"${STUB_BIN}/az" <<'STUB'
#!/usr/bin/env bash
# Fake Azure CLI. Records every call and answers with CRLF line endings.
printf '%s\n' "$*" >>"${AZ_CALL_LOG:-/dev/null}"

emit() { printf '%s\r\n' "$1"; }

state="${FAKE_STATE:-missing}"
sub="${FAKE_SUBSCRIPTION_ID}"
base="/subscriptions/${sub}/resourceGroups/rg-cost-copilot-staging"
shared="/subscriptions/${sub}/resourceGroups/rg-cost-copilot-shared"
profile_id="${shared}/providers/Microsoft.Cdn/profiles/afd-cost-copilot"
endpoint_id="${profile_id}/afdEndpoints/cost-copilot-staging"
aca_env_id="${base}/providers/Microsoft.App/managedEnvironments/cae-cost-copilot-staging"
law_id="${base}/providers/Microsoft.OperationalInsights/workspaces/log-cost-copilot-staging"
appi_id="${base}/providers/Microsoft.Insights/components/appi-cost-copilot-staging"
pec_base="${aca_env_id}/privateEndpointConnections"

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
    # A JMESPath array projected to tsv is one value PER LINE, not a tab row.
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

  "tag list"*)
    emit '{"properties":{"tags":{}}}'
    ;;
  "tag update"*)
    emit '{}'
    ;;

  # -- prerequisites -------------------------------------------------------
  "afd profile show"*)
    emit "$profile_id"
    ;;
  "afd endpoint show"*)
    case "$*" in
      *"--query hostName"*) emit "cost-copilot-staging-abc.z01.azurefd.net" ;;
      *) emit "$endpoint_id" ;;
    esac
    ;;
  "containerapp env show"*)
    emit "$aca_env_id"
    ;;
  "monitor log-analytics workspace show"*)
    emit "$law_id"
    ;;
  "monitor app-insights component show"*)
    emit "$appi_id"
    ;;
  "containerapp show"*)
    app_name="$(arg_value --name "$@")"
    case "$*" in
      *ingress.fqdn*) emit "${app_name}.internal.orangeplant-1234abcd.indonesiacentral.azurecontainerapps.io" ;;
      *) emit "${base}/providers/Microsoft.App/containerApps/${app_name}" ;;
    esac
    ;;

  # -- origin groups and origins -------------------------------------------
  # The --help probe has to be matched before the create it looks like.
  "afd origin create --help"*)
    if [ "${FAKE_PRIVATE_LINK_FLAGS:-explicit}" = "shared" ]; then
      emit "    [--shared-private-link-resource]"
    else
      emit "    [--enable-private-link {0,1,f,false,n,no,t,true,y,yes}]"
      emit "    [--private-link-location]"
      emit "    [--private-link-resource]"
      emit "    [--private-link-sub-resource-type]"
    fi
    ;;
  "afd origin-group show"*)
    [ "$state" = "missing" ] && exit 1
    emit "${profile_id}/originGroups/$(arg_value --origin-group-name "$@")"
    ;;
  "afd origin-group create"*)
    emit '{}'
    ;;
  "afd origin show"*)
    [ "$state" = "missing" ] && exit 1
    emit "${profile_id}/originGroups/og/origins/$(arg_value --origin-name "$@")"
    ;;
  "afd origin create"*)
    emit '{}'
    ;;

  # -- routes --------------------------------------------------------------
  "afd route show"*)
    [ "$state" = "missing" ] && exit 1
    emit "${endpoint_id}/routes/$(arg_value --route-name "$@")"
    ;;
  "afd route create"*)
    emit '{}'
    ;;

  # -- private endpoint connections ----------------------------------------
  # Three pending requests: two raised by this environment's origins and one
  # raised by somebody else. Only the first two may ever be approved.
  "network private-endpoint-connection list"*)
    emit "[{\"id\":\"${pec_base}/pec-frontend\",\"properties\":{\"privateLinkServiceConnectionState\":{\"status\":\"Pending\",\"description\":\"cost-copilot-afd staging frontend\"}}},{\"id\":\"${pec_base}/pec-backend\",\"properties\":{\"privateLinkServiceConnectionState\":{\"status\":\"Pending\",\"description\":\"cost-copilot-afd staging backend\"}}},{\"id\":\"${pec_base}/pec-intruder\",\"properties\":{\"privateLinkServiceConnectionState\":{\"status\":\"Pending\",\"description\":\"someone elses front door\"}}}]"
    ;;
  "network private-endpoint-connection approve"*)
    emit '{}'
    ;;

  # -- diagnostics ---------------------------------------------------------
  "monitor diagnostic-settings categories list"*)
    emit '{"value":[{"name":"FrontDoorAccessLog","categoryType":"Logs"},{"name":"FrontDoorHealthProbeLog","categoryType":"Logs"},{"name":"FrontDoorWebApplicationFirewallLog","categoryType":"Logs"},{"name":"AllMetrics","categoryType":"Metrics"}]}'
    ;;
  "monitor diagnostic-settings show"*)
    [ "$state" = "equal" ] || exit 1
    emit "$law_id"
    ;;
  "monitor diagnostic-settings create"*)
    emit '{}'
    ;;

  # -- alerts --------------------------------------------------------------
  "monitor action-group show"*)
    [ "$state" = "equal" ] || exit 1
    emit "${base}/providers/Microsoft.Insights/actionGroups/ag-cost-copilot"
    ;;
  "monitor action-group create"*)
    emit "${base}/providers/Microsoft.Insights/actionGroups/ag-cost-copilot"
    ;;
  "monitor metrics alert show"*)
    [ "$state" = "equal" ] || exit 1
    emit "${base}/providers/Microsoft.Insights/metricAlerts/$(arg_value --name "$@")"
    ;;
  "monitor metrics alert create"*)
    emit '{}'
    ;;
  "monitor scheduled-query show"*)
    [ "$state" = "equal" ] || exit 1
    emit "${base}/providers/Microsoft.Insights/scheduledQueryRules/$(arg_value --name "$@")"
    ;;
  "monitor scheduled-query create"*)
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
# Routes
# ---------------------------------------------------------------------------

@test "the endpoint gets a frontend /* route and a more specific backend /api/* route" {
  run bash "${FRONTDOOR_SCRIPT}" staging
  [ "$status" -eq 0 ]

  az_calls | grep -q "afd route create --route-name route-frontend-staging .* --patterns-to-match /\*"
  az_calls | grep -q "afd route create --route-name route-api-staging .* --patterns-to-match /api/\*"

  # Both routes hang off the same endpoint ...
  [ "$(az_calls | grep -c "afd route create .* --endpoint-name cost-copilot-staging")" -eq 3 ]
  # ... and each points at its own origin group.
  az_calls | grep -q "afd route create --route-name route-api-staging .* --origin-group og-backend-staging"
  az_calls | grep -q "afd route create --route-name route-frontend-staging .* --origin-group og-frontend-staging"
}

@test "the backend health prefix is routed to the backend, not to the SPA" {
  run bash "${FRONTDOOR_SCRIPT}" staging
  [ "$status" -eq 0 ]

  az_calls | grep -q "afd route create --route-name route-health-staging .* --patterns-to-match /health/\*"
  az_calls | grep -q "afd route create --route-name route-health-staging .* --origin-group og-backend-staging"
}

@test "the backend route pattern outranks the catch-all, which is what decides precedence" {
  # Front Door routes have no priority field, so the script asserts the pattern
  # specificity itself and says so on stderr.
  run bash "${FRONTDOOR_SCRIPT}" staging
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "route precedence"
  echo "$output" | grep -q "'/api/\*'"
}

@test "a catch-all backend pattern is refused instead of silently shadowing the SPA" {
  export AFD_BACKEND_ROUTE_PATTERN="/*"

  run bash "${FRONTDOOR_SCRIPT}" staging
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "must look like '/api/\*'"
  ! az_calls | grep -q "afd route create"
}

@test "forwarding to the origins is HTTPS only" {
  run bash "${FRONTDOOR_SCRIPT}" staging
  [ "$status" -eq 0 ]
  [ "$(az_calls | grep -c "afd route create .* --forwarding-protocol HttpsOnly")" -eq 3 ]
}

# ---------------------------------------------------------------------------
# Private link
# ---------------------------------------------------------------------------

@test "private link origins target the managed environment resource id" {
  run bash "${FRONTDOOR_SCRIPT}" staging
  [ "$status" -eq 0 ]

  local expected="/subscriptions/439cf6ec-8907-40ee-bae2-7efd9656cd09/resourceGroups/rg-cost-copilot-staging/providers/Microsoft.App/managedEnvironments/cae-cost-copilot-staging"

  az_calls | grep -q "afd origin create --origin-name origin-frontend-staging .* --private-link-resource ${expected} "
  az_calls | grep -q "afd origin create --origin-name origin-backend-staging .* --private-link-resource ${expected} "
  [ "$(az_calls | grep -c "afd origin create .* --private-link-sub-resource-type managedEnvironments")" -eq 2 ]
  [ "$(az_calls | grep -c "afd origin create .* --enable-private-link true")" -eq 2 ]
  [ "$(az_calls | grep -c "afd origin create .* --private-link-location indonesiacentral")" -eq 2 ]
}

@test "the origins send the internal ingress FQDN as host name and host header" {
  run bash "${FRONTDOOR_SCRIPT}" staging
  [ "$status" -eq 0 ]

  az_calls | grep -q "afd origin create --origin-name origin-backend-staging .* --host-name ca-cc-backend-staging.internal\."
  az_calls | grep -q "afd origin create --origin-name origin-backend-staging .* --origin-host-header ca-cc-backend-staging.internal\."
}

@test "an Azure CLI that only offers --shared-private-link-resource is still handled" {
  export FAKE_PRIVATE_LINK_FLAGS="shared"

  run bash "${FRONTDOOR_SCRIPT}" staging
  [ "$status" -eq 0 ]
  az_calls | grep -q "afd origin create .* --shared-private-link-resource "
  ! az_calls | grep -q "afd origin create .* --enable-private-link"
  echo "$output" | grep -q "not verified against a live deployment"
}

@test "only the pending requests raised by this environment are approved" {
  run bash "${FRONTDOOR_SCRIPT}" staging
  [ "$status" -eq 0 ]

  az_calls | grep -q "network private-endpoint-connection approve --id .*/pec-frontend "
  az_calls | grep -q "network private-endpoint-connection approve --id .*/pec-backend "

  # The unrelated request stays pending. This is the whole point of matching on
  # the per-environment request message instead of approving what is pending.
  ! az_calls | grep -q "pec-intruder"
  [ "$(az_calls | grep -c "network private-endpoint-connection approve")" -eq 2 ]
  echo "$output" | grep -q "1 pending private endpoint connection"
}

@test "an existing origin is not recreated, so no second private link request is raised" {
  export FAKE_STATE="equal"

  run bash "${FRONTDOOR_SCRIPT}" staging
  [ "$status" -eq 0 ]
  ! az_calls | grep -q "afd origin create --origin-name"
  ! az_calls | grep -q "afd origin-group create"
  ! az_calls | grep -q "afd route create"
}

# ---------------------------------------------------------------------------
# No WAF
# ---------------------------------------------------------------------------

@test "no WAF or security policy is created or attached" {
  run bash "${FRONTDOOR_SCRIPT}" staging
  [ "$status" -eq 0 ]

  # Private Link into an internal Container Apps environment is the security
  # boundary here; the workshop deliberately ships no WAF.
  ! az_calls | grep -qi "waf-policy"
  ! az_calls | grep -qi "security-policy"
  ! az_calls | grep -qi "network front-door waf"
  ! az_calls | grep -q "afd route create .* --rule-sets"

  # ... and the script says so in its own output document.
  bash "${FRONTDOOR_SCRIPT}" staging 2>/dev/null |
    jq -e '.frontDoor.wafPolicy == null'
}

@test "Front Door access and health probe logs go to this environment's workspace" {
  run bash "${FRONTDOOR_SCRIPT}" staging
  [ "$status" -eq 0 ]

  # Front Door is global but a diagnostic setting is named, so each environment
  # ships its own copy to its own workspace.
  az_calls | grep -q "monitor diagnostic-settings create --name cost-copilot-afd-staging"
  az_calls | grep -q "monitor diagnostic-settings create .* --workspace .*/workspaces/log-cost-copilot-staging"
  az_calls | grep -q "monitor diagnostic-settings create .* --resource .*/profiles/afd-cost-copilot"
}

# ---------------------------------------------------------------------------
# Alerts and diagnostics
# ---------------------------------------------------------------------------

@test "the five deployment alerts are created" {
  run bash "${FRONTDOOR_SCRIPT}" staging
  [ "$status" -eq 0 ]

  az_calls | grep -q "monitor metrics alert create --name alert-staging-backend-5xx"
  az_calls | grep -q "monitor metrics alert create --name alert-staging-backend-restarts"
  az_calls | grep -q "monitor metrics alert create --name alert-staging-failed-dependencies"
  az_calls | grep -q "monitor scheduled-query create --name alert-staging-p95-duration"
  az_calls | grep -q "monitor scheduled-query create --name alert-staging-no-telemetry"
}

@test "the 5xx alert filters on the status code category dimension" {
  run bash "${FRONTDOOR_SCRIPT}" staging
  [ "$status" -eq 0 ]
  az_calls | grep -q "alert-staging-backend-5xx .* where statusCodeCategory includes 5xx"
}

@test "existing alerts and diagnostics are left alone on a re-run" {
  export FAKE_STATE="equal"

  run bash "${FRONTDOOR_SCRIPT}" staging
  [ "$status" -eq 0 ]
  ! az_calls | grep -q "monitor metrics alert create"
  ! az_calls | grep -q "monitor scheduled-query create"
  ! az_calls | grep -q "monitor diagnostic-settings create"
  ! az_calls | grep -q "monitor action-group create"
}

@test "the environment argument is validated before anything is touched" {
  run bash "${FRONTDOOR_SCRIPT}" nonsense
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "unknown environment"
  [ ! -s "${AZ_CALL_LOG}" ]
}
