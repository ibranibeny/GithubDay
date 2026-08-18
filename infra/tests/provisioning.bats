#!/usr/bin/env bats
#
# Unit tests for infra/scripts/provision-shared.sh and
# infra/scripts/provision-environment.sh.
#
# No Azure call is ever made: `az` is replaced by a stub executable placed
# first on PATH. A PATH stub is required rather than a shell function because
# azval and az_do call `command az`, which bypasses functions and aliases but
# still honours PATH.
#
# The stub deliberately terminates every line with CRLF, exactly like the
# Windows az.cmd reached through WSL, so the tests exercise the CR stripping
# the real environment depends on. `az account show --query '[a,b,c]' -o tsv'
# is emitted one value per line, which is what the real CLI does with a
# JMESPath array - a tab-delimited row would hide the parsing bug this project
# already hit once.
#
# `jq` is NOT stubbed. The scripts use it for every JSON decision and for the
# output document, so the tests run the real binary.
#
# Every stub invocation is appended to $AZ_CALL_LOG, which is how the tests
# tell "created", "updated" and "left alone" apart.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPTS_DIR="${REPO_ROOT}/infra/scripts"
  SHARED_SCRIPT="${SCRIPTS_DIR}/provision-shared.sh"
  ENVIRONMENT_SCRIPT="${SCRIPTS_DIR}/provision-environment.sh"

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

  # missing | equal | drift - drives every "show" the stub answers.
  export FAKE_STATE="missing"
  # The environment shown in the tags the stub reports; tests that provision an
  # environment set this to staging so ensure_tags sees no drift.
  export FAKE_TAG_ENVIRONMENT="shared"
  # The registry is a prerequisite of provision-environment.sh, so it is
  # controlled separately from the resources under test.
  export FAKE_ACR_STATE=""

  # Keep the role-assignment retry from sleeping if a test ever exercises it.
  export ROLE_ASSIGNMENT_RETRY_DELAY=0
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
acr_state="${FAKE_ACR_STATE:-$state}"
sub="${FAKE_SUBSCRIPTION_ID}"
base="/subscriptions/${sub}/resourceGroups/rg-fake"
law_id="${base}/providers/Microsoft.OperationalInsights/workspaces/log-fake"
acr_id="${base}/providers/Microsoft.ContainerRegistry/registries/crfake"
foundry_id="${base}/providers/Microsoft.CognitiveServices/accounts/aisdgkwm01"

# arg_value <flag> <all args...> - echo the value that follows <flag>.
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

identity_id_for() { printf '%s/providers/Microsoft.ManagedIdentity/userAssignedIdentities/%s' "$base" "$1"; }
principal_id_for() {
  case "$1" in
    *backend*) printf '00000000-0000-0000-0000-0000000000b1' ;;
    *) printf '00000000-0000-0000-0000-0000000000f1' ;;
  esac
}

tags_json() {
  local owner="bibrani@contoso.day"
  if [ "$state" = "drift" ]; then
    owner="someone-else@example.test"
  fi
  printf '{"properties":{"tags":{"repository":"ibranibeny/GithubDay","environment":"%s","owner":"%s","workshop":"azure-cost-copilot"}}}' \
    "${FAKE_TAG_ENVIRONMENT:-shared}" "$owner"
}

case "$*" in
  version*)
    emit "${FAKE_AZ_VERSION:-2.84.0}"
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

  # -- tags ----------------------------------------------------------------
  "tag list"*)
    if [ "$state" = "missing" ]; then
      emit '{"properties":{"tags":{}}}'
    else
      emit "$(tags_json)"
    fi
    ;;
  "tag update"*)
    emit '{}'
    ;;

  # -- resource groups -----------------------------------------------------
  "group show"*)
    [ "$state" = "missing" ] && exit 1
    emit "{\"id\":\"${base}\",\"name\":\"$(arg_value --name "$@")\"}"
    ;;
  "group create"*)
    emit "$base"
    ;;

  # -- container registry --------------------------------------------------
  "acr show"*)
    [ "$acr_state" = "missing" ] && exit 1
    if [ "$acr_state" = "drift" ]; then
      emit "{\"id\":\"${acr_id}\",\"loginServer\":\"crfake.azurecr.io\",\"sku\":{\"name\":\"Basic\"},\"adminUserEnabled\":true}"
    else
      emit "{\"id\":\"${acr_id}\",\"loginServer\":\"crfake.azurecr.io\",\"sku\":{\"name\":\"Standard\"},\"adminUserEnabled\":false}"
    fi
    ;;
  "acr create"*)
    emit "$acr_id"
    ;;
  "acr update"*)
    emit '{}'
    ;;

  # -- front door ----------------------------------------------------------
  "afd profile show"*)
    [ "$state" = "missing" ] && exit 1
    if [ "$state" = "drift" ]; then
      emit "{\"id\":\"${base}/providers/Microsoft.Cdn/profiles/afd-fake\",\"sku\":{\"name\":\"Standard_AzureFrontDoor\"}}"
    else
      emit "{\"id\":\"${base}/providers/Microsoft.Cdn/profiles/afd-fake\",\"sku\":{\"name\":\"Premium_AzureFrontDoor\"}}"
    fi
    ;;
  "afd profile create"*)
    emit "${base}/providers/Microsoft.Cdn/profiles/afd-fake"
    ;;
  "afd profile update"*)
    emit '{}'
    ;;
  "afd endpoint show"*)
    [ "$state" = "missing" ] && exit 1
    case "$*" in
      *"--query hostName"*)
        emit "endpoint-fake.z01.azurefd.net"
        ;;
      *)
        if [ "$state" = "drift" ]; then
          emit "{\"id\":\"${base}/providers/Microsoft.Cdn/profiles/afd-fake/afdEndpoints/e\",\"hostName\":\"endpoint-fake.z01.azurefd.net\",\"enabledState\":\"Disabled\"}"
        else
          emit "{\"id\":\"${base}/providers/Microsoft.Cdn/profiles/afd-fake/afdEndpoints/e\",\"hostName\":\"endpoint-fake.z01.azurefd.net\",\"enabledState\":\"Enabled\"}"
        fi
        ;;
    esac
    ;;
  "afd endpoint create"*)
    emit "${base}/providers/Microsoft.Cdn/profiles/afd-fake/afdEndpoints/e"
    ;;
  "afd endpoint update"*)
    emit '{}'
    ;;

  # -- networking ----------------------------------------------------------
  "network vnet subnet show"*)
    [ "$state" = "missing" ] && exit 1
    subnet_name="$(arg_value --name "$@")"
    case "$subnet_name" in
      snet-aca-infra)
        if [ "$state" = "drift" ]; then
          emit "{\"id\":\"${base}/providers/Microsoft.Network/virtualNetworks/v/subnets/${subnet_name}\",\"addressPrefix\":\"${FAKE_ACA_SUBNET_PREFIX:-10.20.0.0/23}\",\"delegations\":[]}"
        else
          emit "{\"id\":\"${base}/providers/Microsoft.Network/virtualNetworks/v/subnets/${subnet_name}\",\"addressPrefix\":\"${FAKE_ACA_SUBNET_PREFIX:-10.20.0.0/23}\",\"delegations\":[{\"serviceName\":\"Microsoft.App/environments\"}]}"
        fi
        ;;
      *)
        if [ "$state" = "drift" ]; then
          emit "{\"id\":\"${base}/providers/Microsoft.Network/virtualNetworks/v/subnets/${subnet_name}\",\"addressPrefix\":\"${FAKE_PE_SUBNET_PREFIX:-10.20.2.0/24}\",\"privateEndpointNetworkPolicies\":\"Enabled\"}"
        else
          emit "{\"id\":\"${base}/providers/Microsoft.Network/virtualNetworks/v/subnets/${subnet_name}\",\"addressPrefix\":\"${FAKE_PE_SUBNET_PREFIX:-10.20.2.0/24}\",\"privateEndpointNetworkPolicies\":\"Disabled\"}"
        fi
        ;;
    esac
    ;;
  "network vnet subnet create"*)
    emit "${base}/providers/Microsoft.Network/virtualNetworks/v/subnets/$(arg_value --name "$@")"
    ;;
  "network vnet subnet update"*)
    emit '{}'
    ;;
  "network vnet show"*)
    [ "$state" = "missing" ] && exit 1
    emit "{\"id\":\"${base}/providers/Microsoft.Network/virtualNetworks/v\",\"addressSpace\":{\"addressPrefixes\":[\"${FAKE_VNET_PREFIX:-10.20.0.0/16}\"]}}"
    ;;
  "network vnet create"*)
    emit "${base}/providers/Microsoft.Network/virtualNetworks/v"
    ;;

  # -- observability -------------------------------------------------------
  "monitor log-analytics workspace show"*)
    [ "$state" = "missing" ] && exit 1
    emit "{\"id\":\"${law_id}\",\"customerId\":\"11111111-1111-1111-1111-111111111111\"}"
    ;;
  "monitor log-analytics workspace create"*)
    emit "$law_id"
    ;;
  "monitor app-insights component show"*)
    [ "$state" = "missing" ] && exit 1
    if [ "$state" = "drift" ]; then
      emit "{\"id\":\"${base}/providers/Microsoft.Insights/components/appi-fake\",\"workspaceResourceId\":\"\"}"
    else
      emit "{\"id\":\"${base}/providers/Microsoft.Insights/components/appi-fake\",\"workspaceResourceId\":\"${law_id}\"}"
    fi
    ;;
  "monitor app-insights component create"*)
    emit "${base}/providers/Microsoft.Insights/components/appi-fake"
    ;;
  "monitor app-insights component update"*)
    emit '{}'
    ;;
  "monitor diagnostic-settings categories list"*)
    emit '{"value":[{"name":"ContainerAppConsoleLogs","categoryType":"Logs"},{"name":"AllMetrics","categoryType":"Metrics"}]}'
    ;;
  "monitor diagnostic-settings show"*)
    [ "$state" = "equal" ] || exit 1
    emit "$law_id"
    ;;
  "monitor diagnostic-settings create"*)
    emit '{}'
    ;;

  # -- container apps ------------------------------------------------------
  "containerapp env show"*)
    [ "$state" = "missing" ] && exit 1
    case "$*" in
      *publicNetworkAccess*)
        if [ "$state" = "drift" ]; then emit "Enabled"; else emit "Disabled"; fi
        ;;
      *)
        emit "{\"id\":\"${base}/providers/Microsoft.App/managedEnvironments/cae-fake\",\"properties\":{\"vnetConfiguration\":{\"internal\":true},\"publicNetworkAccess\":\"Disabled\"}}"
        ;;
    esac
    ;;
  "containerapp env create"*)
    emit "${base}/providers/Microsoft.App/managedEnvironments/cae-fake"
    ;;
  "containerapp env update"*)
    emit '{}'
    ;;
  "containerapp show"*)
    [ "$state" = "missing" ] && exit 1
    app_name="$(arg_value --name "$@")"
    identity_id="$(identity_id_for "$(printf '%s' "$app_name" | sed 's/^ca-cc-/id-cost-copilot-/')")"
    case "$*" in
      *registries*)
        if [ "$state" = "drift" ]; then emit ""; else emit "$identity_id"; fi
        ;;
      *)
        emit "{\"id\":\"${base}/providers/Microsoft.App/containerApps/${app_name}\",\"identity\":{\"userAssignedIdentities\":{\"${identity_id}\":{}}}}"
        ;;
    esac
    ;;
  "containerapp create"*)
    emit "${base}/providers/Microsoft.App/containerApps/$(arg_value --name "$@")"
    ;;
  "containerapp identity assign"*)
    emit '{}'
    ;;
  "containerapp registry set"*)
    emit '{}'
    ;;

  # -- identities and roles ------------------------------------------------
  "identity show"*)
    [ "$state" = "missing" ] && exit 1
    identity_name="$(arg_value --name "$@")"
    emit "{\"id\":\"$(identity_id_for "$identity_name")\",\"principalId\":\"$(principal_id_for "$identity_name")\",\"clientId\":\"00000000-0000-0000-0000-00000000c1c1\"}"
    ;;
  "identity create"*)
    identity_name="$(arg_value --name "$@")"
    emit "{\"id\":\"$(identity_id_for "$identity_name")\",\"principalId\":\"$(principal_id_for "$identity_name")\",\"clientId\":\"00000000-0000-0000-0000-00000000c1c1\"}"
    ;;
  "role assignment list"*)
    [ "$state" = "equal" ] || exit 0
    emit "${base}/providers/Microsoft.Authorization/roleAssignments/00000000-0000-0000-0000-00000000ra01"
    ;;
  "role assignment create"*)
    emit '{}'
    ;;

  # -- foundry -------------------------------------------------------------
  "cognitiveservices account show"*)
    emit "$foundry_id"
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
# lib.sh idempotency helpers
# ---------------------------------------------------------------------------

@test "ensure_tags leaves a resource alone when every required tag matches" {
  export FAKE_STATE="equal"
  # shellcheck source=../scripts/lib.sh
  source "${SCRIPTS_DIR}/lib.sh"

  run ensure_tags "/subscriptions/s/resourceGroups/g" \
    "repository=ibranibeny/GithubDay" "environment=shared" \
    "owner=bibrani@contoso.day" "workshop=azure-cost-copilot"

  [ "$status" -eq 0 ]
  ! az_calls | grep -q "^tag update"
}

@test "ensure_tags merges the required tags when one of them drifted" {
  export FAKE_STATE="drift"
  # shellcheck source=../scripts/lib.sh
  source "${SCRIPTS_DIR}/lib.sh"

  run ensure_tags "/subscriptions/s/resourceGroups/g" \
    "repository=ibranibeny/GithubDay" "environment=shared" \
    "owner=bibrani@contoso.day" "workshop=azure-cost-copilot"

  [ "$status" -eq 0 ]
  az_calls | grep -q "^tag update .* --operation Merge"
}

@test "ensure_role_assignment does not re-create an assignment that exists" {
  export FAKE_STATE="equal"
  # shellcheck source=../scripts/lib.sh
  source "${SCRIPTS_DIR}/lib.sh"

  run ensure_role_assignment "00000000-0000-0000-0000-0000000000b1" \
    "Cost Management Reader" "/subscriptions/s"

  [ "$status" -eq 0 ]
  ! az_calls | grep -q "^role assignment create"
}

@test "ensure_role_assignment creates the assignment when it is missing" {
  export FAKE_STATE="missing"
  # shellcheck source=../scripts/lib.sh
  source "${SCRIPTS_DIR}/lib.sh"

  run ensure_role_assignment "00000000-0000-0000-0000-0000000000b1" \
    "Cost Management Reader" "/subscriptions/s"

  [ "$status" -eq 0 ]
  az_calls | grep -q "role assignment create .* --assignee-principal-type ServicePrincipal"
}

# ---------------------------------------------------------------------------
# provision-shared.sh
# ---------------------------------------------------------------------------

@test "shared provisioning creates every resource when nothing exists" {
  export FAKE_STATE="missing"

  run bash "${SHARED_SCRIPT}"
  [ "$status" -eq 0 ]

  az_calls | grep -q "^group create --name rg-cost-copilot-shared"
  az_calls | grep -q "^acr create --name crcostcopilot439cf6ec"
  az_calls | grep -q "acr create .* --admin-enabled false"
  az_calls | grep -q "^afd profile create --profile-name afd-cost-copilot .* --sku Premium_AzureFrontDoor"
  az_calls | grep -q "afd endpoint create --endpoint-name cost-copilot-staging"
  az_calls | grep -q "afd endpoint create --endpoint-name cost-copilot-production"
}

@test "shared provisioning emits the names and ids as JSON on stdout" {
  export FAKE_STATE="missing"

  # bats' `run` merges stderr into $output, so stdout is captured separately
  # here. That also proves the machine-readable stream carries no log lines.
  bash "${SHARED_SCRIPT}" >"${TEST_TMPDIR}/shared.json" 2>"${TEST_TMPDIR}/shared.log"

  jq -e '.containerRegistry.name == "crcostcopilot439cf6ec"' <"${TEST_TMPDIR}/shared.json"
  jq -e '.containerRegistry.adminUserEnabled == false' <"${TEST_TMPDIR}/shared.json"
  jq -e '.frontDoor.endpoints.staging.id | length > 0' <"${TEST_TMPDIR}/shared.json"
  jq -e '.frontDoor.endpoints.production.id | length > 0' <"${TEST_TMPDIR}/shared.json"
}

@test "shared provisioning changes nothing when every resource already matches" {
  export FAKE_STATE="equal"

  run bash "${SHARED_SCRIPT}"
  [ "$status" -eq 0 ]

  ! az_calls | grep -q "^group create"
  ! az_calls | grep -q "^acr create"
  ! az_calls | grep -q "^acr update"
  ! az_calls | grep -q "^afd profile create"
  ! az_calls | grep -q "^afd profile update"
  ! az_calls | grep -q "^afd endpoint create"
  ! az_calls | grep -q "^afd endpoint update"
  ! az_calls | grep -q "^tag update"
}

@test "shared provisioning repairs a drifted registry, profile, endpoint and tags" {
  export FAKE_STATE="drift"

  run bash "${SHARED_SCRIPT}"
  [ "$status" -eq 0 ]

  # Nothing is re-created ...
  ! az_calls | grep -q "^acr create"
  ! az_calls | grep -q "^afd endpoint create"
  # ... but each drifted property is corrected.
  az_calls | grep -q "acr update .* --sku Standard"
  az_calls | grep -q "acr update .* --admin-enabled false"
  az_calls | grep -q "afd profile update .* --sku Premium_AzureFrontDoor"
  az_calls | grep -q "afd endpoint update .* --enabled-state Enabled"
  az_calls | grep -q "^tag update .* --operation Merge"
}

@test "shared provisioning refuses to run against the wrong subscription" {
  export FAKE_STATE="missing"
  export FAKE_SUBSCRIPTION_ID="88888888-8888-8888-8888-888888888888"

  run bash "${SHARED_SCRIPT}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"wrong subscription"* ]]

  ! az_calls | grep -q "^group create"
  ! az_calls | grep -q "^acr create"
  ! az_calls | grep -q "^afd profile create"
}

@test "shared provisioning refuses to run against the wrong tenant" {
  export FAKE_STATE="missing"
  export FAKE_TENANT_ID="99999999-9999-9999-9999-999999999999"

  run bash "${SHARED_SCRIPT}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"wrong Entra ID tenant"* ]]

  ! az_calls | grep -q "^acr create"
}

# ---------------------------------------------------------------------------
# provision-environment.sh
# ---------------------------------------------------------------------------

@test "environment provisioning rejects an unknown environment name" {
  run bash "${ENVIRONMENT_SCRIPT}" sandbox
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown environment 'sandbox'"* ]]

  [ ! -s "${AZ_CALL_LOG}" ]
}

@test "environment provisioning requires an environment argument" {
  run bash "${ENVIRONMENT_SCRIPT}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage:"* ]]
}

@test "environment provisioning creates every resource when nothing exists" {
  export FAKE_STATE="missing"
  export FAKE_ACR_STATE="equal"

  run bash "${ENVIRONMENT_SCRIPT}" staging
  [ "$status" -eq 0 ]

  az_calls | grep -q "^group create --name rg-cost-copilot-staging"
  az_calls | grep -q "network vnet create --name vnet-cost-copilot-staging .* --address-prefixes 10.20.0.0/16"
  az_calls | grep -q "network vnet subnet create --name snet-aca-infra .* --address-prefixes 10.20.0.0/23 --delegations Microsoft.App/environments"
  az_calls | grep -q "network vnet subnet create --name snet-private-endpoints .* --disable-private-endpoint-network-policies true"
  az_calls | grep -q "monitor log-analytics workspace create --workspace-name log-cost-copilot-staging"
  az_calls | grep -q "monitor app-insights component create --app appi-cost-copilot-staging .* --workspace .* --kind web --application-type web"
  az_calls | grep -q "containerapp env create --name cae-cost-copilot-staging .* --enable-workload-profiles true"
  az_calls | grep -q "containerapp env create .* --internal-only true"
  az_calls | grep -q "identity create --name id-cost-copilot-backend-staging"
  az_calls | grep -q "identity create --name id-cost-copilot-frontend-staging"
  az_calls | grep -q "containerapp create --name ca-cc-backend-staging"
  az_calls | grep -q "containerapp create --name ca-cc-frontend-staging"
  az_calls | grep -q "containerapp registry set .* --identity "
  az_calls | grep -q "monitor diagnostic-settings create --name cost-copilot-diagnostics"
}

@test "environment provisioning wires the Container Apps environment into the delegated subnet" {
  export FAKE_STATE="missing"
  export FAKE_ACR_STATE="equal"

  run bash "${ENVIRONMENT_SCRIPT}" staging
  [ "$status" -eq 0 ]

  az_calls | grep -q "containerapp env create .* --infrastructure-subnet-resource-id .*subnets/snet-aca-infra"
  az_calls | grep -q "containerapp env create .* --logs-destination azure-monitor"
}

@test "environment provisioning grants the backend identity cost and model access" {
  export FAKE_STATE="missing"
  export FAKE_ACR_STATE="equal"

  run bash "${ENVIRONMENT_SCRIPT}" staging
  [ "$status" -eq 0 ]

  az_calls | grep -q "role assignment create --assignee-object-id 00000000-0000-0000-0000-0000000000b1 .* --role Cost Management Reader --scope /subscriptions/439cf6ec-8907-40ee-bae2-7efd9656cd09"
  az_calls | grep -q "role assignment create --assignee-object-id 00000000-0000-0000-0000-0000000000b1 .* --role Cognitive Services OpenAI User --scope .*Microsoft.CognitiveServices/accounts/aisdgkwm01"
}

@test "environment provisioning never grants the frontend identity cost or model access" {
  export FAKE_STATE="missing"
  export FAKE_ACR_STATE="equal"

  run bash "${ENVIRONMENT_SCRIPT}" staging
  [ "$status" -eq 0 ]

  # The frontend principal is 0000000000f1. It may appear only with AcrPull.
  ! az_calls | grep "role assignment create" | grep "0000000000f1" | grep -q "Cost Management Reader"
  ! az_calls | grep "role assignment create" | grep "0000000000f1" | grep -q "Cognitive Services OpenAI User"
  az_calls | grep "role assignment create" | grep "0000000000f1" | grep -q "AcrPull"
}

@test "environment provisioning changes nothing when every resource already matches" {
  export FAKE_STATE="equal"
  export FAKE_TAG_ENVIRONMENT="staging"

  run bash "${ENVIRONMENT_SCRIPT}" staging
  [ "$status" -eq 0 ]

  ! az_calls | grep -q "^group create"
  ! az_calls | grep -q "^network vnet create"
  ! az_calls | grep -q "^network vnet subnet create"
  ! az_calls | grep -q "^network vnet subnet update"
  ! az_calls | grep -q "^monitor log-analytics workspace create"
  ! az_calls | grep -q "^monitor app-insights component create"
  ! az_calls | grep -q "^monitor app-insights component update"
  ! az_calls | grep -q "^containerapp env create"
  ! az_calls | grep -q "^containerapp env update"
  ! az_calls | grep -q "^containerapp create"
  ! az_calls | grep -q "^containerapp identity assign"
  ! az_calls | grep -q "^containerapp registry set"
  ! az_calls | grep -q "^identity create"
  ! az_calls | grep -q "^role assignment create"
  ! az_calls | grep -q "^monitor diagnostic-settings create"
  ! az_calls | grep -q "^tag update"
}

@test "environment provisioning repairs drifted subnets, identity wiring and tags" {
  export FAKE_STATE="drift"
  export FAKE_TAG_ENVIRONMENT="staging"
  export FAKE_ACR_STATE="equal"

  run bash "${ENVIRONMENT_SCRIPT}" staging
  [ "$status" -eq 0 ]

  # Existing resources are reused ...
  ! az_calls | grep -q "^network vnet create"
  ! az_calls | grep -q "^network vnet subnet create"
  ! az_calls | grep -q "^containerapp env create"
  ! az_calls | grep -q "^containerapp create"
  # ... and the drifted properties are corrected.
  az_calls | grep -q "network vnet subnet update --name snet-aca-infra .* --delegations Microsoft.App/environments"
  az_calls | grep -q "network vnet subnet update --name snet-private-endpoints .* --disable-private-endpoint-network-policies true"
  az_calls | grep -q "monitor app-insights component update .* --workspace "
  az_calls | grep -q "containerapp env update .* --public-network-access Disabled"
  az_calls | grep -q "^containerapp registry set"
  az_calls | grep -q "^tag update .* --operation Merge"
}

@test "environment provisioning emits the names and ids as JSON on stdout" {
  export FAKE_STATE="missing"
  export FAKE_ACR_STATE="equal"

  bash "${ENVIRONMENT_SCRIPT}" staging >"${TEST_TMPDIR}/staging.json" 2>"${TEST_TMPDIR}/staging.log"

  jq -e '.environment == "staging"' <"${TEST_TMPDIR}/staging.json"
  jq -e '.containerAppsEnvironment.internalOnly == true' <"${TEST_TMPDIR}/staging.json"
  jq -e '.backend.appName == "ca-cc-backend-staging"' <"${TEST_TMPDIR}/staging.json"
  jq -e '[.frontend.roles[].role] == ["AcrPull"]' <"${TEST_TMPDIR}/staging.json"
  jq -e '[.backend.roles[].role] | index("Cost Management Reader") != null' <"${TEST_TMPDIR}/staging.json"
}

@test "environment provisioning refuses to run against the wrong subscription" {
  export FAKE_STATE="missing"
  export FAKE_ACR_STATE="equal"
  export FAKE_SUBSCRIPTION_ID="88888888-8888-8888-8888-888888888888"

  run bash "${ENVIRONMENT_SCRIPT}" staging
  [ "$status" -ne 0 ]
  [[ "$output" == *"wrong subscription"* ]]

  ! az_calls | grep -q "^group create"
  ! az_calls | grep -q "^identity create"
  ! az_calls | grep -q "^role assignment create"
  ! az_calls | grep -q "^containerapp create"
}

@test "environment provisioning stops when the shared registry is missing" {
  export FAKE_STATE="missing"
  export FAKE_ACR_STATE="missing"

  run bash "${ENVIRONMENT_SCRIPT}" staging
  [ "$status" -ne 0 ]
  [[ "$output" == *"provision-shared.sh"* ]]

  ! az_calls | grep -q "^group create"
}
