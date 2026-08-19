#!/usr/bin/env bats
#
# Unit tests for infra/scripts/preflight.sh and infra/scripts/lib.sh.
#
# No real Azure or GitHub call is made: `az`, `gh` and `jq` are replaced by stub
# executables placed first on PATH. A PATH stub (rather than a shell function) is
# required because azval calls `command az`, which bypasses functions and aliases
# but still honours PATH.
#
# The az stub deliberately terminates every line with CRLF, exactly like the
# Windows az.cmd reached through WSL, so the tests exercise the azval behaviour
# the real environment depends on.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPTS_DIR="${REPO_ROOT}/infra/scripts"
  PREFLIGHT="${SCRIPTS_DIR}/preflight.sh"

  TEST_TMPDIR="${BATS_TEST_TMPDIR:-$(mktemp -d)}"
  STUB_BIN="${TEST_TMPDIR}/bin"
  mkdir -p "${STUB_BIN}"

  write_az_stub
  write_gh_stub
  write_jq_stub

  PATH="${STUB_BIN}:${PATH}"
  export PATH

  # Stub behaviour knobs. Individual tests override these before calling run.
  export FAKE_AZ_VERSION="2.84.0"
  export FAKE_GH_VERSION="2.62.0"
  export FAKE_TENANT_ID="a1571616-cb5c-4d81-93ab-83c3856d83f2"
  export FAKE_SUBSCRIPTION_ID="439cf6ec-8907-40ee-bae2-7efd9656cd09"
  export FAKE_PROVIDER_STATE="Registered"
  export FAKE_ACA_LOCATIONS="Indonesia Central"
  export FAKE_SIGNED_IN_USER_OBJECT_ID="00000000-0000-0000-0000-0000000000aa"
  export FAKE_CALLER_ROLES="Owner"
  export FAKE_ACR_AVAILABLE="true"
  export FAKE_AFD_AVAILABLE="true"
  export FAKE_COST_QUERY_OK="1"
  export FAKE_ACCOUNT_STATE="Succeeded"
  export FAKE_DEPLOYMENT_STATE="Succeeded"
  export FAKE_DEPLOYMENT_CAPACITY="250"

  # Operator input that preflight requires.
  export WORKSHOP_GROUP_OBJECT_ID="11111111-2222-3333-4444-555555555555"
}

write_az_stub() {
  cat >"${STUB_BIN}/az" <<'STUB'
#!/usr/bin/env bash
# Fake Azure CLI. Emits CRLF line endings like the Windows az.cmd under WSL.
emit() { printf '%s\r\n' "$1"; }

case "$*" in
  version*)
    emit "${FAKE_AZ_VERSION}"
    ;;
  "account show"*)
    # A JMESPath array projected to tsv is one value PER LINE, not a tab row.
    emit "${FAKE_TENANT_ID}"
    emit "${FAKE_SUBSCRIPTION_ID}"
    emit "stub@example.test"
    ;;
  *managedEnvironments*)
    emit "East US"
    emit "${FAKE_ACA_LOCATIONS}"
    ;;
  "provider show"*)
    emit "${FAKE_PROVIDER_STATE}"
    ;;
  "ad signed-in-user show"*)
    emit "${FAKE_SIGNED_IN_USER_OBJECT_ID}"
    ;;
  "role assignment list"*)
    emit "${FAKE_CALLER_ROLES}"
    ;;
  "acr show"*)
    exit 1
    ;;
  "acr check-name"*)
    emit "${FAKE_ACR_AVAILABLE}"
    ;;
  "afd endpoint show"*)
    exit 1
    ;;
  *checkNameAvailability*)
    emit "${FAKE_AFD_AVAILABLE}"
    ;;
  *CostManagement/query*)
    if [ "${FAKE_COST_QUERY_OK}" = "1" ]; then emit '{}'; else exit 1; fi
    ;;
  *CostManagement/dimensions*)
    if [ "${FAKE_COST_DIMENSIONS_OK:-1}" = "1" ]; then emit '{}'; else exit 1; fi
    ;;
  "cognitiveservices account deployment show"*)
    if [ -z "${FAKE_DEPLOYMENT_STATE}" ]; then exit 1; fi
    case "$*" in
      *sku.capacity*) emit "${FAKE_DEPLOYMENT_CAPACITY}" ;;
      *) emit "${FAKE_DEPLOYMENT_STATE}" ;;
    esac
    ;;
  "cognitiveservices account show"*)
    if [ -z "${FAKE_ACCOUNT_STATE}" ]; then exit 1; fi
    case "$*" in
      *properties.endpoint*) emit "https://aisdgkwm01.openai.azure.com/" ;;
      *) emit "${FAKE_ACCOUNT_STATE}" ;;
    esac
    ;;
  stub-crlf*)
    printf 'Enabled\r\n'
    ;;
  *)
    printf 'unhandled az stub invocation: %s\n' "$*" >&2
    exit 1
    ;;
esac
STUB
  chmod +x "${STUB_BIN}/az"
}

write_gh_stub() {
  cat >"${STUB_BIN}/gh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  --version) printf 'gh version %s (2025-01-01)\n' "${FAKE_GH_VERSION}" ;;
  auth) exit "${FAKE_GH_AUTH_EXIT:-0}" ;;
  repo) printf '{"name":"GithubDay"}\n' ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "${STUB_BIN}/gh"
}

write_jq_stub() {
  cat >"${STUB_BIN}/jq" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  --version) printf 'jq-%s\n' "${FAKE_JQ_VERSION:-1.7.1}" ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "${STUB_BIN}/jq"
}

# ---------------------------------------------------------------------------
# lib.sh unit tests
# ---------------------------------------------------------------------------

@test "azval strips the CRLF that the Windows Azure CLI emits" {
  # shellcheck source=../scripts/lib.sh
  source "${SCRIPTS_DIR}/lib.sh"

  local value
  value="$(azval stub-crlf)"

  # Without azval this comparison fails, because the raw value is 'Enabled\r'.
  [ "$value" = "Enabled" ]
  [ "$(printf '%s' "$value" | wc -c)" -eq 7 ]
}

@test "azval propagates the Azure CLI exit code" {
  # shellcheck source=../scripts/lib.sh
  source "${SCRIPTS_DIR}/lib.sh"

  run azval acr show --name whatever
  [ "$status" -ne 0 ]
}

@test "load_config lets the existing environment win over the file" {
  # shellcheck source=../scripts/lib.sh
  source "${SCRIPTS_DIR}/lib.sh"

  export ACA_LOCATION="westeurope"
  load_config "${REPO_ROOT}/infra/config/shared.env"

  [ "$ACA_LOCATION" = "westeurope" ]
  [ "$FOUNDRY_DEPLOYMENT" = "gpt-5.4-mini" ]
}

@test "config_value reads a single key without exporting it" {
  # shellcheck source=../scripts/lib.sh
  source "${SCRIPTS_DIR}/lib.sh"

  run config_value "${REPO_ROOT}/infra/config/staging.env" APP_ENVIRONMENT
  [ "$status" -eq 0 ]
  [ "$output" = "staging" ]
}

# ---------------------------------------------------------------------------
# preflight.sh behaviour
# ---------------------------------------------------------------------------

@test "preflight reports READY when every check passes" {
  run bash "${PREFLIGHT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"READY"* ]]
}

@test "preflight rejects the wrong tenant" {
  export FAKE_TENANT_ID="99999999-9999-9999-9999-999999999999"
  run bash "${PREFLIGHT}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"wrong Entra ID tenant"* ]]
  [[ "$output" != *"READY"* ]]
}

@test "preflight rejects the wrong subscription" {
  export FAKE_SUBSCRIPTION_ID="88888888-8888-8888-8888-888888888888"
  run bash "${PREFLIGHT}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"wrong subscription"* ]]
  [[ "$output" != *"READY"* ]]
}

@test "preflight dies when WORKSHOP_GROUP_OBJECT_ID is missing" {
  unset WORKSHOP_GROUP_OBJECT_ID
  run bash "${PREFLIGHT}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"WORKSHOP_GROUP_OBJECT_ID"* ]]
  [[ "$output" != *"READY"* ]]
}

@test "preflight rejects a region without Container Apps support" {
  export ACA_LOCATION="westeurope"
  run bash "${PREFLIGHT}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not available in westeurope"* ]]
  [[ "$output" != *"READY"* ]]
}

@test "preflight fails when the Foundry model deployment is absent" {
  export FAKE_DEPLOYMENT_STATE=""
  run bash "${PREFLIGHT}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"gpt-5.4-mini"* ]]
  [[ "$output" == *"not found"* ]]
  [[ "$output" != *"READY"* ]]
}

@test "preflight fails when an unregistered resource provider is found" {
  export FAKE_PROVIDER_STATE="NotRegistered"
  run bash "${PREFLIGHT}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Microsoft.App"* ]]
  [[ "$output" != *"READY"* ]]
}

@test "preflight fails when Cost Management is unreadable" {
  export FAKE_COST_QUERY_OK="0"
  export FAKE_COST_DIMENSIONS_OK="0"
  run bash "${PREFLIGHT}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Cost Management"* ]]
  [[ "$output" != *"READY"* ]]
}

@test "preflight fails when the container registry name is taken" {
  export FAKE_ACR_AVAILABLE="false"
  run bash "${PREFLIGHT}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"container registry name"* ]]
}

@test "preflight fails when the GitHub CLI is not authenticated" {
  export FAKE_GH_AUTH_EXIT="1"
  run bash "${PREFLIGHT}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"GitHub CLI is not authenticated"* ]]
}

@test "preflight fails when the Azure CLI is too old" {
  export FAKE_AZ_VERSION="2.40.0"
  run bash "${PREFLIGHT}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"older than the required"* ]]
}
