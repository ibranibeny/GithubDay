# Azure Cost Copilot - fixed, non-secret values shared by every environment.
#
# Loaded by infra/scripts/lib.sh (load_config). Values already present in the
# process environment win, so CI can override any entry without editing files.
# Never put secrets, keys, tokens or connection strings in this file.

AZURE_SUBSCRIPTION_ID=439cf6ec-8907-40ee-bae2-7efd9656cd09
AZURE_TENANT_ID=a1571616-cb5c-4d81-93ab-83c3856d83f2
ACA_LOCATION=indonesiacentral
FOUNDRY_LOCATION=eastus2
FOUNDRY_RESOURCE_GROUP=lab-ai-demo
FOUNDRY_ACCOUNT_NAME=aisdgkwm01
FOUNDRY_DEPLOYMENT=gpt-5.4-mini
GITHUB_OWNER=ibranibeny
GITHUB_REPOSITORY=GithubDay

# ---------------------------------------------------------------------------
# Tags applied to every provisioned resource.
# The repository tag is derived from GITHUB_OWNER/GITHUB_REPOSITORY.
# ---------------------------------------------------------------------------

WORKSHOP_NAME=azure-cost-copilot
WORKSHOP_OWNER=bibrani@contoso.day

# ---------------------------------------------------------------------------
# SKUs of the shared resources.
# ---------------------------------------------------------------------------

# Standard keeps the registry inside the workshop budget; managed-identity
# pulls (AcrPull) work on every tier, so Premium is not required here.
ACR_SKU=Standard

# Premium is required for the private-link origins configured in Task 13.
AFD_SKU=Premium_AzureFrontDoor

# ---------------------------------------------------------------------------
# Container Apps bootstrap defaults.
# Provisioning creates each container app from a public placeholder image; the
# deployment workflows replace the image, the target port and the replica
# counts afterwards. Provisioning never overwrites an app that already exists.
# ---------------------------------------------------------------------------

BOOTSTRAP_IMAGE=mcr.microsoft.com/k8se/quickstart:latest
BOOTSTRAP_TARGET_PORT=80
ACA_WORKLOAD_PROFILE_NAME=Consumption
ACA_MIN_REPLICAS=0
ACA_MAX_REPLICAS=2

# Log Analytics retention in days (30 is the free-tier allowance).
LOG_ANALYTICS_RETENTION_DAYS=30
