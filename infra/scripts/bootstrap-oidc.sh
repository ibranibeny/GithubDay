#!/usr/bin/env bash
#
# bootstrap-oidc.sh - one-time Entra ID and GitHub OIDC bootstrap.
#
# ---------------------------------------------------------------------------
# WHY THIS IS THE ONLY STEP THAT CANNOT RUN THROUGH OIDC
#
# Every other Azure operation in this repository runs from GitHub Actions with a
# workload-identity federation (OIDC) login: no secrets, no service-principal
# passwords. That trust does not exist yet the first time around - this script is
# what creates it. Bootstrapping OIDC with OIDC is impossible, so this script
# alone runs on the operator's workstation under an existing interactive
# `az login`, plus an authenticated `gh`.
#
# Run it once, review the printed IDs, and then never run anything else locally.
# ---------------------------------------------------------------------------
#
# The script is idempotent: every object is looked up first and only created when
# missing. It prints object IDs, client IDs and resource names. It never creates
# or prints a client secret, certificate, registry password or access token -
# workload identity federation removes the need for all of them.
#
# Usage:
#   export WORKSHOP_GROUP_OBJECT_ID=<object id of the workshop Entra ID group>
#   bash infra/scripts/bootstrap-oidc.sh
#
# Optional environment variables:
#   DRY_RUN=1                  print the mutating calls instead of running them
#   GRANT_DEPLOY_ROLES=0       skip the subscription role grants
#   SKIP_GITHUB=1              skip every GitHub API call
#   STAGING_FRONTDOOR_HOSTNAME / PRODUCTION_FRONTDOOR_HOSTNAME
#                              Front Door host names for the SPA redirect URIs.
#                              They only exist after Task 12/13 provisioning, so
#                              the usual sequence is: run this script, provision,
#                              then re-run this script with the host names set.
#   STAGING_APPINSIGHTS_CONNECTION_STRING / PRODUCTION_APPINSIGHTS_CONNECTION_STRING
#                              stored with `gh secret set` when provided.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
. "${SCRIPT_DIR}/lib.sh"

INFRA_CONFIG_DIR="${INFRA_CONFIG_DIR:-${SCRIPT_DIR}/../config}"

API_APP_DISPLAY_NAME="${API_APP_DISPLAY_NAME:-Azure Cost Copilot API}"
SPA_APP_DISPLAY_NAME="${SPA_APP_DISPLAY_NAME:-Azure Cost Copilot SPA}"

# Fixed identifiers keep re-runs idempotent: Entra ID matches app roles and
# delegated scopes by id, not by value.
COST_READ_APP_ROLE_ID="${COST_READ_APP_ROLE_ID:-3f1a6b52-1c2f-4c0e-9a2f-6f8a0d1e7b41}"
COST_READ_SCOPE_ID="${COST_READ_SCOPE_ID:-7c9d2e18-5b44-4a6d-8f13-2b7e5c0a9d36}"

GRAPH_BASE="https://graph.microsoft.com/v1.0"
OIDC_ISSUER="https://token.actions.githubusercontent.com"
OIDC_AUDIENCE="api://AzureADTokenExchange"

TEST_IDENTITY_NAME="${TEST_IDENTITY_NAME:-id-cost-copilot-deploy-test}"

DRY_RUN="${DRY_RUN:-0}"
GRANT_DEPLOY_ROLES="${GRANT_DEPLOY_ROLES:-1}"
SKIP_GITHUB="${SKIP_GITHUB:-0}"

trap cleanup_temp_files EXIT

# ---------------------------------------------------------------------------
# Microsoft Graph helpers
# ---------------------------------------------------------------------------

# Request bodies are passed by file because `az` may be the Windows CLI reached
# through WSL, where inline JSON quoting is unreliable.
graph_request() {
  local method="$1" url="$2" payload="${3:-}"

  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN: ${method} ${url}"
    return 0
  fi
  if [ -z "$payload" ]; then
    azval rest --method "$method" --url "$url"
    return 0
  fi
  az_body_file "$payload" || die "could not stage the request body for ${url}"
  azval rest --method "$method" --url "$url" \
    --headers "Content-Type=application/json" --body "@${AZ_BODY_FILE}"
}

# ---------------------------------------------------------------------------
# Entra ID application registrations
# ---------------------------------------------------------------------------

# ensure_app <displayName> - echo the application (client) ID.
ensure_app() {
  local display_name="$1" client_id
  client_id="$(azval ad app list --display-name "$display_name" --query "[0].appId" --output tsv 2>/dev/null || true)"
  if [ -n "$client_id" ]; then
    log "app registration '${display_name}' already exists (appId ${client_id})"
    printf '%s' "$client_id"
    return 0
  fi
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN: az ad app create --display-name '${display_name}'"
    printf ''
    return 0
  fi
  client_id="$(azval ad app create --display-name "$display_name" \
    --sign-in-audience AzureADMyOrg --query appId --output tsv)"
  [ -n "$client_id" ] || die "failed to create the app registration '${display_name}'"
  ok "created app registration '${display_name}' (appId ${client_id})"
  printf '%s' "$client_id"
}

# app_object_id <appId> - echo the Graph object ID of an application.
app_object_id() {
  azval ad app show --id "$1" --query id --output tsv 2>/dev/null || true
}

# ensure_service_principal <appId> - echo the service principal object ID.
ensure_service_principal() {
  local client_id="$1" object_id
  object_id="$(azval ad sp show --id "$client_id" --query id --output tsv 2>/dev/null || true)"
  if [ -n "$object_id" ]; then
    log "service principal for ${client_id} already exists (objectId ${object_id})"
    printf '%s' "$object_id"
    return 0
  fi
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN: az ad sp create --id ${client_id}"
    printf ''
    return 0
  fi
  object_id="$(azval ad sp create --id "$client_id" --query id --output tsv)"
  ok "created service principal for ${client_id} (objectId ${object_id})"
  printf '%s' "$object_id"
}

# The API app exposes both shapes of Cost.Read:
#   * the app role -> the `roles` claim the FastAPI dependency checks;
#   * the delegated scope -> what the SPA asks for as api://<apiClientId>/Cost.Read.
#
# The app role allows both the "User" and "Application" member types. "User"
# covers the workshop group (its members get the role in their delegated tokens);
# "Application" is what lets the OIDC deploy-test identity's service principal
# hold the role, so the app-only token the live-api E2E suite mints with
# `az account get-access-token --resource api://<apiClientId>` carries
# `roles: ["Cost.Read"]`. Microsoft Graph rejects a service-principal
# appRoleAssignment for a role that does not allow the Application member type.
#
# Microsoft Graph replaces a complex property wholesale on PATCH, so the whole
# `api` object (scope plus pre-authorization) has to be sent in one request.
# Pre-authorising the SPA removes the consent prompt without needing a tenant
# administrator to run `az ad app permission admin-consent`.
configure_api_app() {
  local api_client_id="$1" spa_client_id="$2" object_id payload
  object_id="$(app_object_id "$api_client_id")"
  if [ -z "$object_id" ] && [ "$DRY_RUN" != "1" ]; then
    die "could not resolve the object ID of the API app registration"
  fi

  payload="$(
    cat <<JSON
{
  "identifierUris": ["api://${api_client_id}"],
  "appRoles": [
    {
      "id": "${COST_READ_APP_ROLE_ID}",
      "allowedMemberTypes": ["User", "Application"],
      "displayName": "Cost.Read",
      "value": "Cost.Read",
      "description": "Read Azure cost data through the Cost Copilot API.",
      "isEnabled": true
    }
  ],
  "api": {
    "requestedAccessTokenVersion": 2,
    "oauth2PermissionScopes": [
      {
        "id": "${COST_READ_SCOPE_ID}",
        "value": "Cost.Read",
        "type": "User",
        "isEnabled": true,
        "adminConsentDisplayName": "Read Azure cost data",
        "adminConsentDescription": "Allows the Cost Copilot single-page application to read Azure cost data on behalf of the signed-in user.",
        "userConsentDisplayName": "Read your Azure cost data",
        "userConsentDescription": "Allows the Cost Copilot application to read Azure cost data on your behalf."
      }
    ],
    "preAuthorizedApplications": [
      {
        "appId": "${spa_client_id}",
        "delegatedPermissionIds": ["${COST_READ_SCOPE_ID}"]
      }
    ]
  }
}
JSON
  )"
  graph_request patch "${GRAPH_BASE}/applications/${object_id}" "$payload" >/dev/null
  ok "API app ${api_client_id} exposes app role and scope Cost.Read (identifierUri api://${api_client_id})"
  ok "SPA ${spa_client_id} is pre-authorized for Cost.Read on the API app"
}

configure_spa_app() {
  local spa_client_id="$1" api_client_id="$2"
  shift 2
  local object_id payload spa_fragment=""
  object_id="$(app_object_id "$spa_client_id")"
  if [ -z "$object_id" ] && [ "$DRY_RUN" != "1" ]; then
    die "could not resolve the object ID of the SPA app registration"
  fi

  # Graph replaces the whole redirect URI collection on PATCH, so the property
  # is omitted entirely when no host name is known - otherwise a re-run without
  # host names would delete the URIs registered by an earlier run.
  if [ "$#" -gt 0 ]; then
    spa_fragment="\"spa\": { \"redirectUris\": $(redirect_uri_json "$@") },"
  else
    warn "leaving the existing SPA redirect URIs of ${spa_client_id} unchanged"
  fi

  payload="$(
    cat <<JSON
{
  ${spa_fragment}
  "requiredResourceAccess": [
    {
      "resourceAppId": "${api_client_id}",
      "resourceAccess": [
        { "id": "${COST_READ_SCOPE_ID}", "type": "Scope" }
      ]
    }
  ]
}
JSON
  )"
  graph_request patch "${GRAPH_BASE}/applications/${object_id}" "$payload" >/dev/null
  ok "SPA app ${spa_client_id} requests api://${api_client_id}/Cost.Read"
}

# redirect_uri_json <uri>... - JSON array of the SPA redirect URIs.
redirect_uri_json() {
  local uri first=1
  printf '['
  for uri in "$@"; do
    [ -n "$uri" ] || continue
    if [ "$first" -eq 0 ]; then printf ', '; fi
    printf '"%s"' "$uri"
    first=0
  done
  printf ']'
}

# ---------------------------------------------------------------------------
# Cost.Read app role assignments
# ---------------------------------------------------------------------------

# assign_cost_read_app_role <graph-collection> <principal-object-id> <api-sp-object-id>
#
# Grant the API's Cost.Read app role to one principal. The request body is the
# same whether the principal is a group or a service principal - only the
# collection segment of the Graph URL differs (`groups` vs `servicePrincipals`) -
# so a single function serves both callers and the Graph logic lives in exactly
# one place. Idempotent: the existing assignment is looked up first.
#
#   * the workshop group is assigned through `groups`, so its members carry
#     `roles: ["Cost.Read"]` in the delegated tokens the SPA obtains;
#   * the OIDC deploy-test identity is assigned through `servicePrincipals`, so
#     the app-only token it mints for api://<apiClientId> carries the same claim
#     the backend's require_cost_reader dependency checks. That assignment only
#     succeeds because the Cost.Read app role allows the "Application" member
#     type (see configure_api_app).
assign_cost_read_app_role() {
  local collection="$1" principal_object_id="$2" api_sp_object_id="$3" existing payload

  existing="$(azval rest --method get \
    --url "${GRAPH_BASE}/${collection}/${principal_object_id}/appRoleAssignments?\$select=id,appRoleId,resourceId" \
    --query "value[?appRoleId=='${COST_READ_APP_ROLE_ID}' && resourceId=='${api_sp_object_id}'] | [0].id" \
    --output tsv 2>/dev/null || true)"
  if [ -n "$existing" ] && [ "$existing" != "None" ]; then
    ok "principal ${principal_object_id} already holds the Cost.Read app role"
    return 0
  fi

  payload="$(
    cat <<JSON
{"principalId":"${principal_object_id}","resourceId":"${api_sp_object_id}","appRoleId":"${COST_READ_APP_ROLE_ID}"}
JSON
  )"
  graph_request post "${GRAPH_BASE}/${collection}/${principal_object_id}/appRoleAssignments" "$payload" >/dev/null
  ok "assigned the Cost.Read app role to principal ${principal_object_id} (${collection})"
}

# ---------------------------------------------------------------------------
# Managed identities and federated credentials
# ---------------------------------------------------------------------------

ensure_resource_group() {
  local name="$1" location="$2"
  if azval group show --name "$name" --query id --output tsv >/dev/null 2>&1; then
    ok "resource group ${name} already exists"
    return 0
  fi
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN: az group create --name ${name} --location ${location}"
    return 0
  fi
  azval group create --name "$name" --location "$location" --query id --output tsv >/dev/null
  ok "created resource group ${name} in ${location}"
}

# ensure_identity <name> <resourceGroup> <location> - echo "<clientId>\t<principalId>".
ensure_identity() {
  local name="$1" resource_group="$2" location="$3" values
  values="$(azval identity show --name "$name" --resource-group "$resource_group" \
    --query "[clientId,principalId]" --output tsv 2>/dev/null || true)"
  if [ -n "$values" ]; then
    log "managed identity ${name} already exists"
    printf '%s' "$values"
    return 0
  fi
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN: az identity create --name ${name} --resource-group ${resource_group}"
    printf ''
    return 0
  fi
  values="$(azval identity create --name "$name" --resource-group "$resource_group" \
    --location "$location" --query "[clientId,principalId]" --output tsv)"
  ok "created managed identity ${name}"
  printf '%s' "$values"
}

# ensure_federated_credential <identity> <resourceGroup> <credentialName> <subject>
ensure_federated_credential() {
  local identity="$1" resource_group="$2" credential_name="$3" subject="$4" existing

  existing="$(azval identity federated-credential list \
    --identity-name "$identity" --resource-group "$resource_group" \
    --query "[?subject=='${subject}'] | [0].name" --output tsv 2>/dev/null || true)"
  if [ -n "$existing" ] && [ "$existing" != "None" ]; then
    ok "federated credential for '${subject}' already exists on ${identity} (${existing})"
    return 0
  fi
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN: az identity federated-credential create --name ${credential_name} --subject ${subject}"
    return 0
  fi
  azval identity federated-credential create \
    --name "$credential_name" \
    --identity-name "$identity" \
    --resource-group "$resource_group" \
    --issuer "$OIDC_ISSUER" \
    --subject "$subject" \
    --audiences "$OIDC_AUDIENCE" >/dev/null
  ok "created federated credential ${credential_name} on ${identity} for '${subject}'"
}

grant_subscription_role() {
  local principal_id="$1" role="$2" scope existing
  scope="/subscriptions/${AZURE_SUBSCRIPTION_ID}"

  existing="$(azval role assignment list \
    --assignee-object-id "$principal_id" \
    --scope "$scope" --role "$role" \
    --query "[0].id" --output tsv 2>/dev/null || true)"
  if [ -n "$existing" ] && [ "$existing" != "None" ]; then
    ok "principal ${principal_id} already holds '${role}' on the subscription"
    return 0
  fi
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN: az role assignment create --role '${role}' --assignee-object-id ${principal_id} --scope ${scope}"
    return 0
  fi
  azval role assignment create \
    --assignee-object-id "$principal_id" \
    --assignee-principal-type ServicePrincipal \
    --role "$role" --scope "$scope" --query id --output tsv >/dev/null
  ok "granted '${role}' on the subscription to ${principal_id}"
}

# ---------------------------------------------------------------------------
# GitHub configuration
# ---------------------------------------------------------------------------

github_repository() {
  printf '%s/%s' "$GITHUB_OWNER" "$GITHUB_REPOSITORY"
}

ensure_github_environment() {
  local environment="$1"
  if [ "$SKIP_GITHUB" = "1" ]; then
    log "SKIP_GITHUB=1: not creating GitHub environment ${environment}"
    return 0
  fi
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN: gh api --method PUT repos/$(github_repository)/environments/${environment}"
    return 0
  fi
  gh api --method PUT -H "Accept: application/vnd.github+json" \
    "repos/$(github_repository)/environments/${environment}" >/dev/null
  ok "GitHub environment ${environment} is present"
}

# set_github_variable <name> <value> [environment]
set_github_variable() {
  local name="$1" value="$2" environment="${3:-}"
  if [ -z "$value" ]; then
    warn "skipping GitHub variable ${name}: no value is known yet"
    return 0
  fi
  if [ "$SKIP_GITHUB" = "1" ]; then
    log "SKIP_GITHUB=1: not setting variable ${name}"
    return 0
  fi
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN: gh variable set ${name}${environment:+ --env ${environment}}"
    return 0
  fi
  if [ -n "$environment" ]; then
    gh variable set "$name" --repo "$(github_repository)" --env "$environment" --body "$value"
    ok "set GitHub variable ${name} on environment ${environment}"
  else
    gh variable set "$name" --repo "$(github_repository)" --body "$value"
    ok "set repository-level GitHub variable ${name}"
  fi
}

# set_github_secret <name> <value> <environment> - value is never logged.
set_github_secret() {
  local name="$1" value="$2" environment="$3"
  if [ -z "$value" ]; then
    return 0
  fi
  if [ "$SKIP_GITHUB" = "1" ]; then
    log "SKIP_GITHUB=1: not setting secret ${name}"
    return 0
  fi
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN: gh secret set ${name} --env ${environment}"
    return 0
  fi
  printf '%s' "$value" | gh secret set "$name" --repo "$(github_repository)" --env "$environment"
  ok "set GitHub secret ${name} on environment ${environment} (value not logged)"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  log "one-time Entra ID and GitHub OIDC bootstrap"
  log "this is the only step that cannot use OIDC, because the OIDC trust it creates does not exist yet"
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN=1: no Azure or GitHub object will be created"
  fi

  load_config "${INFRA_CONFIG_DIR}/shared.env"
  require_cmd az gh || die "install the missing command-line tools and re-run"
  require_azure_context

  if [ -z "${WORKSHOP_GROUP_OBJECT_ID:-}" ]; then
    die "WORKSHOP_GROUP_OBJECT_ID is not set. Export the object ID of the Entra ID group that receives the Cost.Read app role."
  fi
  is_guid "$WORKSHOP_GROUP_OBJECT_ID" || die "WORKSHOP_GROUP_OBJECT_ID is not a GUID"

  if [ "$SKIP_GITHUB" != "1" ] && ! gh auth status >/dev/null 2>&1; then
    die "the GitHub CLI is not authenticated; run 'gh auth login' (or export GH_TOKEN) first"
  fi

  local staging_config="${INFRA_CONFIG_DIR}/staging.env"
  local production_config="${INFRA_CONFIG_DIR}/production.env"
  local shared_group
  shared_group="$(config_value "$staging_config" SHARED_RESOURCE_GROUP)"

  # --- Entra ID -----------------------------------------------------------
  local api_client_id spa_client_id api_sp_object_id
  api_client_id="$(ensure_app "$API_APP_DISPLAY_NAME")"
  spa_client_id="$(ensure_app "$SPA_APP_DISPLAY_NAME")"
  configure_api_app "$api_client_id" "$spa_client_id"
  api_sp_object_id="$(ensure_service_principal "$api_client_id")"

  local staging_host production_host
  staging_host="${STAGING_FRONTDOOR_HOSTNAME:-$(config_value "$staging_config" FRONTDOOR_HOSTNAME || true)}"
  production_host="${PRODUCTION_FRONTDOOR_HOSTNAME:-$(config_value "$production_config" FRONTDOOR_HOSTNAME || true)}"

  local -a redirect_uris=()
  if [ -n "$staging_host" ]; then
    redirect_uris+=("https://${staging_host}/")
  fi
  if [ -n "$production_host" ]; then
    redirect_uris+=("https://${production_host}/")
  fi
  if [ "${#redirect_uris[@]}" -eq 0 ]; then
    warn "no Front Door host names are known yet, so no SPA redirect URI is registered."
    warn "provision the Front Door endpoints (Tasks 12-13), then re-run this script with STAGING_FRONTDOOR_HOSTNAME and PRODUCTION_FRONTDOOR_HOSTNAME set."
  fi
  configure_spa_app "$spa_client_id" "$api_client_id" "${redirect_uris[@]+"${redirect_uris[@]}"}"
  ensure_service_principal "$spa_client_id" >/dev/null
  assign_cost_read_app_role groups "$WORKSHOP_GROUP_OBJECT_ID" "$api_sp_object_id"

  # --- Deployment identities ---------------------------------------------
  ensure_resource_group "$shared_group" "$ACA_LOCATION"

  local staging_identity production_identity
  staging_identity="$(config_value "$staging_config" DEPLOY_IDENTITY_NAME)"
  production_identity="$(config_value "$production_config" DEPLOY_IDENTITY_NAME)"

  local staging_values production_values test_values
  local staging_client_id staging_principal_id
  local production_client_id production_principal_id
  local test_client_id test_principal_id

  staging_values="$(ensure_identity "$staging_identity" "$shared_group" "$ACA_LOCATION")"
  { IFS= read -r staging_client_id; IFS= read -r staging_principal_id; } <<<"$staging_values" || true
  production_values="$(ensure_identity "$production_identity" "$shared_group" "$ACA_LOCATION")"
  { IFS= read -r production_client_id; IFS= read -r production_principal_id; } <<<"$production_values" || true
  test_values="$(ensure_identity "$TEST_IDENTITY_NAME" "$shared_group" "$ACA_LOCATION")"
  { IFS= read -r test_client_id; IFS= read -r test_principal_id; } <<<"$test_values" || true

  local repository
  repository="$(github_repository)"

  ensure_federated_credential "$staging_identity" "$shared_group" \
    "github-environment-staging" "repo:${repository}:environment:staging"
  ensure_federated_credential "$staging_identity" "$shared_group" \
    "github-branch-staging" "repo:${repository}:ref:refs/heads/staging"
  ensure_federated_credential "$production_identity" "$shared_group" \
    "github-environment-production" "repo:${repository}:environment:production"
  ensure_federated_credential "$production_identity" "$shared_group" \
    "github-branch-main" "repo:${repository}:ref:refs/heads/main"
  ensure_federated_credential "$TEST_IDENTITY_NAME" "$shared_group" \
    "github-pull-request" "repo:${repository}:pull_request"

  # The live-api E2E suite runs under the deploy-test identity and calls the API
  # with an app-only token for api://<apiClientId>. That token only carries
  # `roles: ["Cost.Read"]` - which the backend requires - if this service
  # principal holds the Cost.Read app role, so assign it here (idempotently),
  # exactly as the workshop group is assigned above via the same helper.
  if [ -n "$test_principal_id" ] && [ -n "$api_sp_object_id" ]; then
    assign_cost_read_app_role servicePrincipals "$test_principal_id" "$api_sp_object_id"
  else
    warn "skipping the Cost.Read app role for the deploy-test identity: its service principal or the API service principal is not known yet"
  fi

  if [ "$GRANT_DEPLOY_ROLES" = "1" ]; then
    local principal
    for principal in "$staging_principal_id" "$production_principal_id"; do
      [ -n "$principal" ] || continue
      # Contributor provisions resources; User Access Administrator creates the
      # runtime role assignments (Cost Management Reader, AcrPull, OpenAI User).
      grant_subscription_role "$principal" "Contributor"
      grant_subscription_role "$principal" "User Access Administrator"
    done
    if [ -n "$test_principal_id" ]; then
      grant_subscription_role "$test_principal_id" "Reader"
    fi
  else
    warn "GRANT_DEPLOY_ROLES=0: no role was granted. The deployment identities need 'Contributor' and 'User Access Administrator' on subscription ${AZURE_SUBSCRIPTION_ID} before Task 12."
  fi

  # --- GitHub -------------------------------------------------------------
  set_github_variable AZURE_TENANT_ID "$AZURE_TENANT_ID"
  set_github_variable AZURE_SUBSCRIPTION_ID "$AZURE_SUBSCRIPTION_ID"
  set_github_variable AZURE_TEST_CLIENT_ID "$test_client_id"

  local environment config client_id host
  for environment in staging production; do
    config="${INFRA_CONFIG_DIR}/${environment}.env"
    ensure_github_environment "$environment"
    if [ "$environment" = "staging" ]; then
      client_id="$staging_client_id"
      host="$staging_host"
    else
      client_id="$production_client_id"
      host="$production_host"
    fi

    set_github_variable AZURE_CLIENT_ID "$client_id" "$environment"
    set_github_variable AZURE_TENANT_ID "$AZURE_TENANT_ID" "$environment"
    set_github_variable AZURE_SUBSCRIPTION_ID "$AZURE_SUBSCRIPTION_ID" "$environment"
    set_github_variable ENTRA_API_CLIENT_ID "$api_client_id" "$environment"
    set_github_variable ENTRA_SPA_CLIENT_ID "$spa_client_id" "$environment"
    set_github_variable APP_ENVIRONMENT "$(config_value "$config" APP_ENVIRONMENT)" "$environment"
    set_github_variable AZURE_RESOURCE_GROUP "$(config_value "$config" RESOURCE_GROUP)" "$environment"
    set_github_variable SHARED_RESOURCE_GROUP "$(config_value "$config" SHARED_RESOURCE_GROUP)" "$environment"
    set_github_variable ACR_NAME "$(config_value "$config" ACR_NAME)" "$environment"
    set_github_variable ACA_ENVIRONMENT_NAME "$(config_value "$config" ACA_ENVIRONMENT_NAME)" "$environment"
    set_github_variable FRONTEND_APP_NAME "$(config_value "$config" FRONTEND_APP_NAME)" "$environment"
    set_github_variable BACKEND_APP_NAME "$(config_value "$config" BACKEND_APP_NAME)" "$environment"
    set_github_variable AFD_PROFILE_NAME "$(config_value "$config" AFD_PROFILE_NAME)" "$environment"
    set_github_variable AFD_ENDPOINT_NAME "$(config_value "$config" AFD_ENDPOINT_NAME)" "$environment"
    set_github_variable ACA_LOCATION "$ACA_LOCATION" "$environment"
    set_github_variable FRONTDOOR_HOSTNAME "$host" "$environment"
  done

  # Application Insights connection strings are the only bootstrap values that
  # are treated as secrets. They exist only after provisioning, so they are
  # optional here.
  set_github_secret APPLICATIONINSIGHTS_CONNECTION_STRING \
    "${STAGING_APPINSIGHTS_CONNECTION_STRING:-}" staging
  set_github_secret APPLICATIONINSIGHTS_CONNECTION_STRING \
    "${PRODUCTION_APPINSIGHTS_CONNECTION_STRING:-}" production

  cat <<SUMMARY
BOOTSTRAP SUMMARY (identifiers only; no credential was created or printed)
  API app (client) ID          : ${api_client_id}
  API service principal object : ${api_sp_object_id}
  SPA app (client) ID          : ${spa_client_id}
  Cost.Read app role ID        : ${COST_READ_APP_ROLE_ID}
  Cost.Read delegated scope ID : ${COST_READ_SCOPE_ID}
  Workshop group object ID     : ${WORKSHOP_GROUP_OBJECT_ID}
  Identity resource group      : ${shared_group}
  Staging deploy client ID     : ${staging_client_id}
  Production deploy client ID  : ${production_client_id}
  Test (pull request) client ID: ${test_client_id}
SUMMARY

  ok "bootstrap complete"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
