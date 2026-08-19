"""Deterministic environment for the unit suite.

The values are assigned at import time (before test modules are imported) so
that modules which build the FastAPI application at import time see a complete,
predictable configuration regardless of the developer's shell environment.
"""

import os

from constants import (
    TEST_API_CLIENT_ID,
    TEST_FOUNDRY_ENDPOINT,
    TEST_SUBSCRIPTION_ID,
    TEST_TENANT_ID,
)

os.environ["AZURE_TENANT_ID"] = TEST_TENANT_ID
os.environ["AZURE_SUBSCRIPTION_ID"] = TEST_SUBSCRIPTION_ID
os.environ["ENTRA_API_CLIENT_ID"] = TEST_API_CLIENT_ID
os.environ["FOUNDRY_ENDPOINT"] = TEST_FOUNDRY_ENDPOINT

for _optional in (
    "AZURE_CLIENT_ID",
    "FOUNDRY_DEPLOYMENT",
    "APPLICATIONINSIGHTS_CONNECTION_STRING",
    "APP_ENVIRONMENT",
    "GIT_SHA",
    "OTEL_SERVICE_VERSION",
    "ALLOWED_ORIGINS",
):
    os.environ.pop(_optional, None)
