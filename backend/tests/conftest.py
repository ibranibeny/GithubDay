"""Deterministic environment for the unit suite.

The values are assigned at import time (before test modules are imported) so
that modules which build the FastAPI application at import time see a complete,
predictable configuration regardless of the developer's shell environment.
"""

import os

TEST_TENANT_ID = "a1571616-cb5c-4d81-93ab-83c3856d83f2"
TEST_SUBSCRIPTION_ID = "439cf6ec-8907-40ee-bae2-7efd9656cd09"
TEST_API_CLIENT_ID = "5f1d0f0e-0000-4000-8000-000000000001"
TEST_FOUNDRY_ENDPOINT = "https://aisdgkwm01.openai.azure.com/openai/v1/"

os.environ["AZURE_TENANT_ID"] = TEST_TENANT_ID
os.environ["AZURE_SUBSCRIPTION_ID"] = TEST_SUBSCRIPTION_ID
os.environ["ENTRA_API_CLIENT_ID"] = TEST_API_CLIENT_ID
os.environ["FOUNDRY_ENDPOINT"] = TEST_FOUNDRY_ENDPOINT

for _optional in (
    "AZURE_CLIENT_ID",
    "FOUNDRY_DEPLOYMENT",
    "APPLICATIONINSIGHTS_CONNECTION_STRING",
    "ALLOWED_ORIGINS",
):
    os.environ.pop(_optional, None)
