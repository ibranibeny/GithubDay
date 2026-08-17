# Azure Cost Copilot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and deploy a live Azure cost analytics dashboard and evidence-grounded GPT-5.4-mini chatbot with isolated staging and production environments.

**Architecture:** A React/TypeScript frontend and Python/FastAPI backend run as separate Azure Container Apps in separate staging and production managed environments in Indonesia Central. Azure Front Door Premium reaches private ACA origins, while the backend uses managed identity to query Azure Cost Management and an existing Microsoft Foundry deployment in East US 2. GitHub Actions uses OIDC, tests staging before opening a promotion PR, and deploys the exact tested image digests to production.

**Tech Stack:** React 19, TypeScript, Vite, TanStack Query, Apache ECharts, MSAL React, Vitest, Playwright, Python 3.13, FastAPI, Pydantic 2, HTTPX, Azure Identity, OpenAI Responses API, Azure Monitor OpenTelemetry, Docker, Nginx, Azure CLI, GitHub Actions, CodeQL.

---

## Delivery Rules

- Work on feature branches created from `staging`; never implement directly on `main`.
- Use TDD for each behavior: failing test, minimal implementation, passing test.
- Keep shell scripts LF-only and validate them with ShellCheck.
- Do not install or invoke npm, pnpm, Yarn, Bun, or Docker on the workshop laptop.
  JavaScript dependency installation, frontend tests/builds, Playwright package
  installation, and image builds run only on GitHub-hosted runners or Azure
  Container Registry build agents.
- Use MCP Playwright for browser interaction and visual verification from VS
  Code. Do not require a locally installed Playwright browser or CLI.
- Never store access tokens, client secrets, Foundry keys, ACR passwords, raw cost payloads, prompts, or model answers in source control or telemetry.
- The one-time OIDC bootstrap runs under the operator's existing `az login`; all subsequent Azure provisioning and deployment runs through GitHub Actions.
- Treat `staging` as integration and `main` as production. Production must deploy image digests already tested in staging.

## Target File Map

```text
.
|-- .env.example                         # local configuration contract
|-- .gitattributes                       # enforce LF for shell/YAML files
|-- .github/
|   |-- dependabot.yml
|   |-- workflows/
|       |-- ci.yml
|       |-- codeql.yml
|       |-- infra.yml
|       |-- deploy-staging.yml
|       |-- promote.yml
|       `-- deploy-production.yml
|-- backend/
|   |-- Dockerfile
|   |-- pyproject.toml
|   |-- src/cost_copilot/
|   |   |-- main.py
|   |   |-- config.py
|   |   |-- telemetry.py
|   |   |-- auth.py
|   |   |-- errors.py
|   |   |-- models/cost.py
|   |   |-- models/chat.py
|   |   |-- clients/cost_management.py
|   |   |-- clients/foundry.py
|   |   |-- services/cost_service.py
|   |   |-- services/chat_service.py
|   |   `-- routers/{health,costs,chat}.py
|   `-- tests/
|       |-- unit/
|       |-- contract/
|       `-- integration/
|-- frontend/
|   |-- Dockerfile
|   |-- nginx.conf
|   |-- package.json
|   |-- playwright.config.ts
|   |-- src/
|   |   |-- main.tsx
|   |   |-- app/App.tsx
|   |   |-- app/runtime-config.ts
|   |   |-- auth/msal.ts
|   |   |-- auth/AuthGate.tsx
|   |   |-- telemetry/app-insights.ts
|   |   |-- api/client.ts
|   |   |-- api/contracts.ts
|   |   |-- features/dashboard/
|   |   `-- features/chat/
|   |-- tests/
|   `-- public/config.template.js
|-- infra/
|   |-- config/{shared,staging,production}.env
|   |-- scripts/lib.sh
|   |-- scripts/preflight.sh
|   |-- scripts/bootstrap-oidc.sh
|   |-- scripts/provision-shared.sh
|   |-- scripts/provision-environment.sh
|   |-- scripts/configure-frontdoor.sh
|   |-- scripts/deploy.sh
|   `-- scripts/verify.sh
|-- tests/e2e/
|   |-- auth-redirect.spec.ts
|   |-- dashboard.spec.ts
|   `-- live-api.spec.ts
`-- README.md
```

## Phase 1: Application Foundation

### Task 1: Establish the Monorepo Toolchains and Shared Contracts

**Files:**
- Create: `.gitattributes`
- Create: `.env.example`
- Create: `backend/pyproject.toml`
- Create: `backend/src/cost_copilot/__init__.py`
- Create: `frontend/package.json`
- Create: `frontend/tsconfig.json`
- Create: `frontend/vite.config.ts`
- Create: `frontend/src/api/contracts.ts`
- Test: `backend/tests/unit/test_imports.py`
- Test: `frontend/src/api/contracts.test.ts`

- [ ] **Step 1: Create the failing backend import smoke test**

```python
# backend/tests/unit/test_imports.py
def test_package_exposes_version() -> None:
    from cost_copilot import __version__

    assert __version__ == "0.1.0"
```

- [ ] **Step 2: Run the backend test and verify RED**

Run: `cd backend && uv run pytest tests/unit/test_imports.py -v`

Expected: FAIL because the package and project metadata do not exist.

- [ ] **Step 3: Create the Python project and package metadata**

Use `uv init --lib --python 3.13`, then set these dependencies in `backend/pyproject.toml`:

```toml
[project]
name = "azure-cost-copilot-api"
version = "0.1.0"
requires-python = ">=3.13"
dependencies = [
  "azure-identity>=1.25,<2",
  "azure-monitor-opentelemetry>=1.8,<2",
  "fastapi>=0.116,<1",
  "httpx>=0.28,<1",
  "openai>=2.46,<3",
  "pydantic-settings>=2.10,<3",
  "pyjwt[crypto]>=2.10,<3",
  "uvicorn[standard]>=0.35,<1",
]

[dependency-groups]
dev = [
  "mypy>=1.17,<2",
  "pytest>=8.4,<9",
  "pytest-asyncio>=1.1,<2",
  "pytest-cov>=6.2,<7",
  "respx>=0.22,<1",
  "ruff>=0.12,<1",
]

[tool.pytest.ini_options]
pythonpath = ["src"]
asyncio_mode = "auto"

[tool.ruff]
line-length = 100

[tool.mypy]
strict = true
```

```python
# backend/src/cost_copilot/__init__.py
__version__ = "0.1.0"
```

- [ ] **Step 4: Run the backend test and verify GREEN**

Run: `cd backend && uv sync && uv run pytest tests/unit/test_imports.py -v`

Expected: `1 passed`.

- [ ] **Step 5: Create the failing frontend contract test**

```typescript
// frontend/src/api/contracts.test.ts
import { describe, expect, it } from "vitest";
import { normalizeCurrency } from "./contracts";

describe("normalizeCurrency", () => {
  it("rejects a response with mixed currencies", () => {
    expect(() => normalizeCurrency(["USD", "IDR"])).toThrow("Mixed currencies");
  });
});
```

- [ ] **Step 6: Scaffold Vite in a GitHub-hosted setup job and implement the shared frontend contracts**

Run only on a GitHub-hosted runner in `frontend/`; do not run these commands on
the workshop laptop:

```bash
npm create vite@latest . -- --template react-ts
npm install @azure/msal-browser @azure/msal-react @microsoft/applicationinsights-web @tanstack/react-query echarts echarts-for-react lucide-react web-vitals zod
npm install --save-dev @playwright/test @testing-library/jest-dom @testing-library/react @testing-library/user-event eslint prettier vitest
```

Add the following contract helper and preserve Vite's generated strict TypeScript settings:

```typescript
// frontend/src/api/contracts.ts
export type CostMetric = "ActualCost" | "AmortizedCost";
export type CostGrouping = "ServiceName" | "ResourceGroupName" | "ResourceId" | "Tag";

export interface CostFilter {
  from: string;
  to: string;
  metric: CostMetric;
  grouping: CostGrouping;
  tagKey?: string;
}

export interface CostPoint {
  date: string;
  amount: number;
  currency: string;
}

export function normalizeCurrency(currencies: string[]): string {
  const unique = new Set(currencies);
  if (unique.size !== 1) throw new Error("Mixed currencies are not supported");
  return currencies[0];
}
```

- [ ] **Step 7: Enforce line endings and validate both toolchains**

```gitattributes
* text=auto
*.sh text eol=lf
*.yml text eol=lf
*.yaml text eol=lf
```

Run in the GitHub-hosted frontend validation job:

```bash
cd frontend && npm test -- --run src/api/contracts.test.ts
cd ../backend && uv run ruff check . && uv run mypy src
```

Expected: frontend test passes; Ruff and mypy exit `0`.

- [ ] **Step 8: Commit**

```bash
git add .gitattributes .env.example backend frontend
git commit -m "chore: initialize frontend and backend toolchains"
```

### Task 2: Implement Configuration, Authentication, and Health Endpoints

**Files:**
- Create: `backend/src/cost_copilot/config.py`
- Create: `backend/src/cost_copilot/auth.py`
- Create: `backend/src/cost_copilot/errors.py`
- Create: `backend/src/cost_copilot/routers/health.py`
- Create: `backend/src/cost_copilot/main.py`
- Test: `backend/tests/unit/test_config.py`
- Test: `backend/tests/unit/test_auth.py`
- Test: `backend/tests/unit/test_health.py`

- [ ] **Step 1: Write failing settings and authorization tests**

```python
# backend/tests/unit/test_config.py
from cost_copilot.config import Settings


def test_subscription_is_fixed_by_configuration() -> None:
    settings = Settings(
        azure_tenant_id="a1571616-cb5c-4d81-93ab-83c3856d83f2",
        azure_subscription_id="439cf6ec-8907-40ee-bae2-7efd9656cd09",
        entra_api_client_id="api-client",
        foundry_endpoint="https://aisdgkwm01.openai.azure.com/openai/v1/",
        foundry_deployment="gpt-5.4-mini",
    )
    assert settings.azure_subscription_id == "439cf6ec-8907-40ee-bae2-7efd9656cd09"
```

```python
# backend/tests/unit/test_auth.py
import pytest
from fastapi import HTTPException
from cost_copilot.auth import require_cost_reader


def test_cost_reader_role_is_required() -> None:
    with pytest.raises(HTTPException) as error:
        require_cost_reader({"roles": ["Other.Role"]})
    assert error.value.status_code == 403
```

- [ ] **Step 2: Verify both tests fail**

Run: `cd backend && uv run pytest tests/unit/test_config.py tests/unit/test_auth.py -v`

Expected: FAIL because settings and auth modules are absent.

- [ ] **Step 3: Implement strict settings and JWT validation**

```python
# backend/src/cost_copilot/config.py
from functools import lru_cache
from pydantic import AnyHttpUrl
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")
    azure_tenant_id: str
    azure_subscription_id: str
    azure_client_id: str | None = None
    entra_api_client_id: str
    foundry_endpoint: AnyHttpUrl
    foundry_deployment: str = "gpt-5.4-mini"
    applicationinsights_connection_string: str | None = None
    allowed_origins: str = "http://localhost:5173"


@lru_cache
def get_settings() -> Settings:
    return Settings()  # type: ignore[call-arg]
```

Implement `auth.py` with `PyJWKClient`, issuer
`https://login.microsoftonline.com/{tenant}/v2.0`, audience equal to
`ENTRA_API_CLIENT_ID`, algorithms restricted to `RS256`, and a dependency that
requires the `Cost.Read` app role:

```python
def require_cost_reader(claims: dict[str, object]) -> dict[str, object]:
    roles = claims.get("roles", [])
    if not isinstance(roles, list) or "Cost.Read" not in roles:
        raise HTTPException(status_code=403, detail="Cost.Read role is required")
    return claims
```

- [ ] **Step 4: Add liveness and readiness tests**

```python
# backend/tests/unit/test_health.py
from fastapi.testclient import TestClient
from cost_copilot.main import app


def test_liveness_is_public() -> None:
    response = TestClient(app).get("/health/live")
    assert response.status_code == 200
    assert response.json() == {"status": "alive"}
```

Implement `/health/live` as process-only and `/health/ready` as a dependency
check that returns `503` when credential, Cost Management, or Foundry preflight
fails. Do not put raw exception text in the response.

- [ ] **Step 5: Run focused tests and static checks**

Run:

```bash
cd backend
uv run pytest tests/unit/test_config.py tests/unit/test_auth.py tests/unit/test_health.py -v
uv run ruff check .
uv run mypy src
```

Expected: all tests pass; Ruff and mypy exit `0`.

- [ ] **Step 6: Commit**

```bash
git add backend/src backend/tests
git commit -m "feat: add API configuration authentication and health"
```

### Task 3: Build the Cost Management Query Client and Read APIs

**Files:**
- Create: `backend/src/cost_copilot/models/cost.py`
- Create: `backend/src/cost_copilot/clients/cost_management.py`
- Create: `backend/src/cost_copilot/services/cost_service.py`
- Create: `backend/src/cost_copilot/routers/costs.py`
- Create: `backend/tests/fixtures/cost-query.json`
- Test: `backend/tests/unit/test_cost_query.py`
- Test: `backend/tests/contract/test_cost_response.py`

- [ ] **Step 1: Write failing query-builder tests**

```python
# backend/tests/unit/test_cost_query.py
from datetime import date
from cost_copilot.models.cost import CostFilter, CostGrouping, CostMetric
from cost_copilot.clients.cost_management import build_query


def test_daily_query_is_bounded_and_grouped() -> None:
    value = CostFilter(
        start=date(2026, 8, 1),
        end=date(2026, 8, 17),
        metric=CostMetric.ACTUAL,
        grouping=CostGrouping.SERVICE,
    )
    query = build_query(value, granularity="Daily")
    assert query["timePeriod"] == {"from": "2026-08-01", "to": "2026-08-17"}
    assert query["dataset"]["grouping"][0]["name"] == "ServiceName"
```

- [ ] **Step 2: Run the focused test and verify RED**

Run: `cd backend && uv run pytest tests/unit/test_cost_query.py -v`

Expected: FAIL because cost models and query builder are absent.

- [ ] **Step 3: Implement bounded Pydantic models and query construction**

`CostFilter` must enforce `end >= start`, a maximum 366-day range, supported
metrics only, and require `tag_key` when grouping by tag. Define the enums and
dimension mapping explicitly:

```python
from datetime import date
from enum import StrEnum
from typing import Self

from pydantic import BaseModel, model_validator


class CostMetric(StrEnum):
    ACTUAL = "ActualCost"
    AMORTIZED = "AmortizedCost"


class CostGrouping(StrEnum):
    SERVICE = "ServiceName"
    RESOURCE_GROUP = "ResourceGroupName"
    RESOURCE = "ResourceId"
    TAG = "Tag"


class CostFilter(BaseModel):
    start: date
    end: date
    metric: CostMetric
    grouping: CostGrouping
    tag_key: str | None = None

    @model_validator(mode="after")
    def validate_range_and_grouping(self) -> Self:
        if self.end < self.start:
            raise ValueError("end must be on or after start")
        if (self.end - self.start).days > 366:
            raise ValueError("date range cannot exceed 366 days")
        if self.grouping is CostGrouping.TAG and not self.tag_key:
            raise ValueError("tag_key is required for tag grouping")
        return self

    @property
    def azure_dimension(self) -> str:
        if self.grouping is CostGrouping.TAG:
            assert self.tag_key is not None
            return self.tag_key
        return self.grouping.value
```

`build_query` must produce structured JSON and never concatenate user values
into a URL. Use grouping type `TagKey` for tag queries and `Dimension` otherwise.

```python
def build_query(filters: CostFilter, granularity: str) -> dict[str, object]:
    grouping_type = "TagKey" if filters.grouping is CostGrouping.TAG else "Dimension"
    return {
        "type": "ActualCost" if filters.metric is CostMetric.ACTUAL else "AmortizedCost",
        "timeframe": "Custom",
        "timePeriod": {"from": filters.start.isoformat(), "to": filters.end.isoformat()},
        "dataset": {
            "granularity": granularity,
            "aggregation": {"totalCost": {"name": "Cost", "function": "Sum"}},
            "grouping": [{"type": grouping_type, "name": filters.azure_dimension}],
        },
    }
```

- [ ] **Step 4: Implement the async Cost Management client**

Use `azure.identity.aio.DefaultAzureCredential` and HTTPX. Acquire a token for
`https://management.azure.com/.default`, then POST only to this configured URL:

```python
url = (
    "https://management.azure.com/subscriptions/"
    f"{settings.azure_subscription_id}/providers/Microsoft.CostManagement/query"
    "?api-version=2025-03-01"
)
```

Apply a 30-second timeout. Retry `429`, `502`, `503`, and `504` at most three
times, honoring `Retry-After`. Map `401`, `403`, throttling, and upstream timeout
to typed application errors without returning ARM response bodies.

- [ ] **Step 5: Add a sanitized contract fixture and response parser test**

Store only synthetic names and amounts in `cost-query.json`. Test that columns
are mapped by name rather than position, currencies cannot be mixed, and an
empty row set returns zero-valued summary data.

- [ ] **Step 6: Implement summary, trend, and breakdown routes**

Routes accept only the fixed subscription from settings and the validated query
parameters. Return typed response models with `generatedAt`, `dataFreshness`,
`currency`, and a `reratingNotice` for the current billing period.

- [ ] **Step 7: Run focused and contract tests**

Run:

```bash
cd backend
uv run pytest tests/unit/test_cost_query.py tests/contract/test_cost_response.py -v
uv run pytest --cov=cost_copilot --cov-report=term-missing
```

Expected: all tests pass and the touched client/service modules have at least 90% branch coverage.

- [ ] **Step 8: Commit**

```bash
git add backend/src/cost_copilot backend/tests
git commit -m "feat: add live Azure cost query APIs"
```

### Task 4: Add Evidence-Grounded Foundry Chat

**Files:**
- Create: `backend/src/cost_copilot/models/chat.py`
- Create: `backend/src/cost_copilot/clients/foundry.py`
- Create: `backend/src/cost_copilot/services/chat_service.py`
- Create: `backend/src/cost_copilot/routers/chat.py`
- Test: `backend/tests/unit/test_chat_service.py`
- Test: `backend/tests/contract/test_foundry_response.py`

- [ ] **Step 1: Write the failing grounding test**

```python
async def test_chat_does_not_call_foundry_when_cost_query_fails(cost_client, foundry_client):
    cost_client.query.side_effect = PermissionError("forbidden")
    service = ChatService(cost_client=cost_client, foundry_client=foundry_client)

    with pytest.raises(CostAccessDenied):
        await service.answer(request)

    foundry_client.respond.assert_not_awaited()
```

- [ ] **Step 2: Verify RED**

Run: `cd backend && uv run pytest tests/unit/test_chat_service.py -v`

Expected: FAIL because chat types and service are absent.

- [ ] **Step 3: Implement the keyless Foundry client**

Follow the official Responses API pattern with the deployment name, not the
catalog model ID:

```python
from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from openai import AsyncOpenAI

token_provider = get_bearer_token_provider(
    DefaultAzureCredential(), "https://cognitiveservices.azure.com/.default"
)
client = AsyncOpenAI(base_url=str(settings.foundry_endpoint), api_key=token_provider)
```

Send normalized evidence as JSON and require structured JSON output containing
`answer`, `evidence[]`, and `chartActions[]`. Use low verbosity and bounded
reasoning effort. Set a 45-second timeout and do not enable web search.

- [ ] **Step 4: Implement evidence validation**

Reject any model evidence reference whose metric, dimension, period, or amount
does not exist in the normalized cost evidence. If validation fails, return the
cost data with `explanationAvailable=false`; never pass through unsupported
claims.

- [ ] **Step 5: Run service and contract tests**

Run: `cd backend && uv run pytest tests/unit/test_chat_service.py tests/contract/test_foundry_response.py -v`

Expected: tests cover valid answer, invalid evidence, empty model output,
timeout, `429`, and Cost Management failure; all pass.

- [ ] **Step 6: Commit**

```bash
git add backend/src/cost_copilot backend/tests
git commit -m "feat: add evidence grounded Foundry chat"
```

### Task 5: Instrument and Sanitize Backend Telemetry

**Files:**
- Create: `backend/src/cost_copilot/telemetry.py`
- Modify: `backend/src/cost_copilot/main.py`
- Modify: `backend/src/cost_copilot/clients/cost_management.py`
- Modify: `backend/src/cost_copilot/clients/foundry.py`
- Test: `backend/tests/unit/test_telemetry.py`

- [ ] **Step 1: Write a failing telemetry sanitization test**

```python
def test_sensitive_fields_are_removed() -> None:
    output = sanitize_attributes({
        "prompt": "show my costs",
        "answer": "USD 100",
        "authorization": "Bearer token",
        "dependency": "cost-management",
    })
    assert output == {"dependency": "cost-management"}
```

- [ ] **Step 2: Configure Azure Monitor before importing FastAPI**

Create `telemetry.py` and call `configure_azure_monitor()` before importing
FastAPI in `main.py`, following Microsoft guidance. Configure service name,
environment, and Git SHA resource attributes. Disable telemetry export when no
Application Insights connection string exists locally.

- [ ] **Step 3: Add safe custom spans and metrics**

Record only dependency name, status, duration, row count, model deployment,
input/output token counts, environment, and correlation ID. Explicitly remove
prompt, answer, authorization headers, query body, resource IDs, and raw cost
rows.

- [ ] **Step 4: Run focused telemetry tests**

Run: `cd backend && uv run pytest tests/unit/test_telemetry.py -v`

Expected: sanitization and disabled-export behavior pass.

- [ ] **Step 5: Commit**

```bash
git add backend/src/cost_copilot backend/tests/unit/test_telemetry.py
git commit -m "feat: instrument backend with Azure Monitor"
```

## Phase 2: Frontend Experience

### Task 6: Implement Runtime Configuration, MSAL, and API Access

**Files:**
- Create: `frontend/public/config.template.js`
- Create: `frontend/src/app/runtime-config.ts`
- Create: `frontend/src/auth/msal.ts`
- Create: `frontend/src/auth/AuthGate.tsx`
- Create: `frontend/src/api/client.ts`
- Test: `frontend/src/app/runtime-config.test.ts`
- Test: `frontend/src/api/client.test.ts`

- [ ] **Step 1: Write failing runtime-config and token tests**

```typescript
it("fails closed when the API client ID is missing", () => {
  expect(() => parseRuntimeConfig({ tenantId: "tenant" })).toThrow("apiClientId");
});

it("adds a bearer token and correlation ID", async () => {
  const response = await apiFetch("/api/costs/summary", tokenProvider);
  expect(fetch).toHaveBeenCalledWith(expect.any(String), expect.objectContaining({
    headers: expect.objectContaining({ Authorization: "Bearer token" }),
  }));
});
```

- [ ] **Step 2: Implement runtime config so one image serves both environments**

`config.template.js` contains placeholders populated at container startup:

```javascript
window.__APP_CONFIG__ = {
  environment: "${APP_ENVIRONMENT}",
  tenantId: "${ENTRA_TENANT_ID}",
  spaClientId: "${ENTRA_SPA_CLIENT_ID}",
  apiClientId: "${ENTRA_API_CLIENT_ID}",
  apiBaseUrl: "${API_BASE_URL}",
  appInsightsConnectionString: "${APPLICATIONINSIGHTS_CONNECTION_STRING}"
};
```

Validate this object with Zod before rendering the application.

- [ ] **Step 3: Implement MSAL and the authenticated fetch client**

Initialize `PublicClientApplication` for the configured tenant. Request scope
`api://{apiClientId}/Cost.Read`, call `acquireTokenSilent` first, and use redirect
only for `InteractionRequiredAuthError`. Never put tokens in application state,
logs, local storage owned by the app, or telemetry.

- [ ] **Step 4: Run focused frontend tests**

Run in GitHub Actions: `cd frontend && npm test -- --run src/app/runtime-config.test.ts src/api/client.test.ts`

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add frontend/public frontend/src/app frontend/src/auth frontend/src/api
git commit -m "feat: add runtime config and Entra authentication"
```

### Task 7: Build the Analytics-First Cost Dashboard

**Files:**
- Create: `frontend/src/app/AppShell.tsx`
- Create: `frontend/src/features/dashboard/CostCommandBar.tsx`
- Create: `frontend/src/features/dashboard/CostDashboard.tsx`
- Create: `frontend/src/features/dashboard/CostFilters.tsx`
- Create: `frontend/src/features/dashboard/KpiStrip.tsx`
- Create: `frontend/src/features/dashboard/CostTrendChart.tsx`
- Create: `frontend/src/features/dashboard/CostBreakdown.tsx`
- Create: `frontend/src/features/dashboard/useCostData.ts`
- Create: `frontend/src/styles/tokens.css`
- Test: `frontend/src/features/dashboard/CostDashboard.test.tsx`

- [ ] **Step 1: Write failing dashboard behavior tests**

Test that changing metric from `ActualCost` to `AmortizedCost` refetches all
queries, a service-bar click changes the active dimension, loading states do not
shift layout, and a `403` renders the exact RBAC guidance rather than an empty
chart.

- [ ] **Step 2: Implement the dashboard data hooks**

Use TanStack Query with keys containing the complete normalized filter. Abort
stale requests and use a five-minute `staleTime` because cost data is not
real-time. Do not cache bearer tokens or raw responses outside Query's memory.

- [ ] **Step 3: Implement the approved visual direction**

Before implementation, the assigned frontend subagent MUST load and follow the
`frontend-design` skill. Use the attached Azure Portal Cost Analysis screenshot
as the primary structural reference, while creating original React components
and charts rather than embedding or tracing the screenshot.

Build an Azure-style operational shell with:

- A narrow left navigation rail containing Overview, Activity log, Access
  control, Resources, **Cost analysis** as the selected item, Monitoring, and
  Help. Collapse it to an icon drawer on small screens.
- A page header showing the subscription name and `Cost analysis`, followed by a
  compact command bar with functional Refresh and Download controls. Do not add
  inert Save/Share buttons.
- A single fixed-height scope strip for subscription, view (`AccumulatedCosts`),
  month/date range, and add-filter controls.
- Three stable KPI blocks for actual cost, forecast, and budget. Budget state
  must visibly distinguish under-budget and over-budget values.
- A large accumulated-cost area chart matching the screenshot's information
  model: actual accumulated cost, over-budget segment, translucent forecast,
  overage forecast, and a dotted monthly-budget reference line.
- Three equal-width donut breakdown panels below the trend chart: Service name,
  Location, and Resource group name, each with a compact ranked legend and exact
  currency values.
- A 360px contextual AI chat rail on wide screens that can collapse without
  resizing chart heights; on tablet/mobile it becomes a full-width lower panel.

Keep sections unframed except for the three repeated breakdown panels and chat
tool. Use square or <=8px corners, dense spacing, visible focus states, stable
chart dimensions, reduced-motion support, Source Sans 3 for interface text, and
IBM Plex Mono for numeric values. Define a multi-hue chart palette derived from
Azure blue, teal, green, amber, red, purple, ink, and neutral gray. Use ECharts
and Lucide icons. Do not create a landing hero, decorative orbs, nested cards,
oversized headings, nonfunctional controls, or a one-hue dashboard.

- [ ] **Step 4: Run component tests and responsive checks**

Run in the GitHub-hosted frontend validation job:

```bash
cd frontend
npm test -- --run src/features/dashboard/CostDashboard.test.tsx
npm run build
```

Use MCP Playwright screenshots at 1440x900, 1024x768, and 390x844 against the
deployed staging URL to verify that the
area chart and all donut charts are nonblank, text does not overlap or overflow,
the chat rail does not resize charts, and the mobile navigation/filter controls
remain usable. Expected: component tests, screenshot checks, accessibility scan,
and production build pass.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/features/dashboard frontend/src/styles
git commit -m "feat: add Azure cost analytics dashboard"
```

### Task 8: Add Contextual Chat, Evidence Actions, and Browser Telemetry

**Files:**
- Create: `frontend/src/features/chat/ChatPanel.tsx`
- Create: `frontend/src/features/chat/EvidenceLink.tsx`
- Create: `frontend/src/features/chat/useCostChat.ts`
- Create: `frontend/src/telemetry/app-insights.ts`
- Modify: `frontend/src/features/dashboard/CostDashboard.tsx`
- Test: `frontend/src/features/chat/ChatPanel.test.tsx`
- Test: `frontend/src/telemetry/app-insights.test.ts`

- [ ] **Step 1: Write failing evidence and privacy tests**

Test that selecting evidence applies its metric/dimension/date range to the
dashboard, chat cannot send without active filters, and telemetry properties do
not contain prompt, answer, token, or amount fields.

- [ ] **Step 2: Implement contextual chat and evidence actions**

Send the prompt plus normalized active filters. Render assistant text as plain
text, not raw HTML. Evidence actions are typed commands such as:

```typescript
type ChartAction = {
  kind: "set-filter" | "highlight-series";
  metric?: CostMetric;
  grouping?: CostGrouping;
  value?: string;
  from?: string;
  to?: string;
};
```

Validate actions before applying them. Preserve visible cost evidence when AI
explanation is unavailable.

- [ ] **Step 3: Configure Application Insights browser telemetry**

Initialize only when a connection string exists. Track page views, Web Vitals,
failed API dependencies, environment, and correlation ID. Add a telemetry
initializer that drops authorization headers and all chat/cost properties.

- [ ] **Step 4: Run focused tests and accessibility scan**

Run in the GitHub-hosted frontend validation job:

```bash
cd frontend
npm test -- --run src/features/chat/ChatPanel.test.tsx src/telemetry/app-insights.test.ts
npm run build
```

Expected: tests and build pass with no TypeScript errors.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/features frontend/src/telemetry
git commit -m "feat: add contextual cost chat and browser telemetry"
```

## Phase 3: Containers and End-to-End Tests

### Task 9: Containerize Both Apps with Runtime Configuration

**Files:**
- Create: `backend/Dockerfile`
- Create: `frontend/Dockerfile`
- Create: `frontend/nginx.conf`
- Create: `frontend/docker-entrypoint.sh`
- Create: `compose.yaml`
- Test: `backend/tests/integration/test_container_health.py`

- [ ] **Step 1: Write the container health test**

The test polls `http://localhost:8000/health/live` for 30 seconds and requires
`{"status":"alive"}`. It must fail before the images exist.

- [ ] **Step 2: Implement minimal non-root images**

Backend: multi-stage Python 3.13 slim image, lockfile-based `uv sync --frozen`,
non-root UID, port 8000, and Uvicorn health check.

Frontend: Node build stage and Nginx unprivileged runtime. The entrypoint runs:

```sh
#!/bin/sh
set -eu
envsubst < /usr/share/nginx/html/config.template.js \
  > /usr/share/nginx/html/config.js
exec nginx -g 'daemon off;'
```

Nginx serves the SPA, `/health/live`, and immutable assets with long cache
headers; `config.js` uses `no-store`.

- [ ] **Step 3: Build and run both containers on GitHub-hosted runners**

Run only in GitHub Actions; Docker is not a laptop prerequisite:

```bash
docker compose build
docker compose up -d
cd backend && uv run pytest tests/integration/test_container_health.py -v
curl --fail http://localhost:8080/health/live
docker compose down
```

Expected: both health checks pass.

- [ ] **Step 4: Scan images**

Run: `docker scout cves azure-cost-copilot-api:local azure-cost-copilot-web:local --only-severity critical,high`

Expected: no known critical or high vulnerability without an explicit documented exception.

- [ ] **Step 5: Commit**

```bash
git add backend/Dockerfile frontend/Dockerfile frontend/nginx.conf frontend/docker-entrypoint.sh compose.yaml
git commit -m "build: containerize frontend and backend"
```

### Task 10: Add Automated UI and Live API Test Suites

**Files:**
- Create: `frontend/playwright.config.ts`
- Create: `tests/e2e/auth-redirect.spec.ts`
- Create: `tests/e2e/dashboard.spec.ts`
- Create: `tests/e2e/live-api.spec.ts`
- Create: `tests/e2e/helpers/token.ts`

- [ ] **Step 1: Add failing unauthenticated and dashboard tests**

`auth-redirect.spec.ts` verifies an anonymous user is redirected to the configured
tenant authority. `dashboard.spec.ts` runs against a local API fixture and checks
filtering, chart rendering, mobile layout, keyboard navigation, and evidence
actions.

- [ ] **Step 2: Add the staging live API test**

Use `az account get-access-token --resource api://$ENTRA_API_CLIENT_ID` under the
GitHub OIDC test identity. Call summary, trend, breakdown, and chat endpoints
through Front Door and assert the subscription is fixed, cost currency is
consistent, evidence validates, and correlation IDs are returned.

- [ ] **Step 3: Document the interactive-login boundary**

GitHub-hosted runners do not automate a human Entra login because MFA and
Conditional Access are interactive. The required automated gate validates the
redirect and all authenticated API behavior with OIDC. The workshop runbook adds
a human acceptance check for browser login before production approval.

- [ ] **Step 4: Run automated Playwright in CI and inspect with MCP Playwright**

Run only on the GitHub-hosted runner:

```bash
cd frontend
npx playwright install --with-deps chromium
npm run test:e2e
```

Expected: desktop and mobile Chromium projects pass. Then use MCP Playwright
against the staging URL to confirm screenshots show no blank chart, overflow,
overlap, or unreadable control text.

- [ ] **Step 5: Commit**

```bash
git add frontend/playwright.config.ts tests/e2e
git commit -m "test: add UI and live staging test suites"
```

## Phase 4: Azure CLI Infrastructure

### Task 11: Implement Preflight and One-Time OIDC Bootstrap

**Files:**
- Create: `infra/config/shared.env`
- Create: `infra/config/staging.env`
- Create: `infra/config/production.env`
- Create: `infra/scripts/lib.sh`
- Create: `infra/scripts/preflight.sh`
- Create: `infra/scripts/bootstrap-oidc.sh`
- Test: `infra/tests/preflight.bats`

- [ ] **Step 1: Write failing shell tests**

Use Bats to verify scripts reject the wrong tenant/subscription, missing
`WORKSHOP_GROUP_OBJECT_ID`, unsupported ACA region, missing Foundry deployment,
and Azure CLI output containing CRLF.

- [ ] **Step 2: Implement common shell safety**

Every script starts with `set -Eeuo pipefail`, imports `lib.sh`, uses `azval` to
strip `\r` from Azure CLI scalar output, quotes variables, and logs resource names
without tokens or connection strings.

`shared.env` contains non-secret fixed values:

```bash
AZURE_SUBSCRIPTION_ID=439cf6ec-8907-40ee-bae2-7efd9656cd09
AZURE_TENANT_ID=a1571616-cb5c-4d81-93ab-83c3856d83f2
ACA_LOCATION=indonesiacentral
FOUNDRY_LOCATION=eastus2
FOUNDRY_RESOURCE_GROUP=lab-ai-demo
FOUNDRY_ACCOUNT_NAME=aisdgkwm01
FOUNDRY_DEPLOYMENT=gpt-5.4-mini
GITHUB_OWNER=ibranibeny
GITHUB_REPOSITORY=GithubDay
```

- [ ] **Step 3: Implement the preflight**

Verify CLI versions, providers, subscription/tenant, permissions, unique ACR/AFD
names, Foundry endpoint and deployment state, GPT quota, Cost Management query
access, required group object ID, and Indonesia Central ACA support. Perform no
mutation.

- [ ] **Step 4: Implement one-time OIDC and Entra bootstrap**

Under the operator's existing `az login`, idempotently create:

- Backend API app registration exposing app role `Cost.Read`.
- SPA app registration with redirect URIs for the two generated Front Door endpoints.
- Assignment of the workshop group to `Cost.Read`.
- Staging, production, and test user-assigned deployment identities.
- Federated credentials for `environment:staging`, `environment:production`,
  pull requests, and the `staging`/`main` branches.
- GitHub Environment variables through `gh variable set`; only encrypted values
  that require secrecy use `gh secret set`.

The script prints IDs, never credentials. It must explain that this is the only
bootstrap step that cannot run through OIDC because OIDC trust does not yet exist.

- [ ] **Step 5: Validate scripts**

Run:

```bash
shellcheck infra/scripts/*.sh
bats infra/tests/preflight.bats
bash infra/scripts/preflight.sh
```

Expected: ShellCheck and Bats pass; preflight reports `READY` without changing Azure.

- [ ] **Step 6: Commit**

```bash
git add infra/config infra/scripts infra/tests
git commit -m "feat: add Azure and OIDC bootstrap scripts"
```

### Task 12: Provision Shared and Environment-Specific Azure Resources

**Files:**
- Create: `infra/scripts/provision-shared.sh`
- Create: `infra/scripts/provision-environment.sh`
- Test: `infra/tests/provisioning.bats`

- [ ] **Step 1: Write idempotency tests around mocked Azure CLI output**

Test create-when-missing, no-op-when-equal, update-when-different, and fail-on-
wrong-subscription behavior for shared and environment resources.

- [ ] **Step 2: Implement shared provisioning**

Create a workshop shared resource group, ACR with admin disabled, and Azure Front
Door Premium profile with two endpoints. Tag every resource with repository,
environment, owner, and workshop. Return names and resource IDs as JSON.

- [ ] **Step 3: Implement `provision-environment.sh staging|production`**

For each environment, idempotently create:

- Resource group in `indonesiacentral`.
- VNet with separate `/23` ACA infrastructure and `/24` private endpoint subnets.
- Log Analytics workspace and workspace-based Application Insights.
- Internal workload-profiles ACA managed environment with public access disabled.
- Backend and frontend user-assigned runtime identities.
- Four Container Apps total across both environments.
- ACR managed-identity pull configuration.
- `Cost Management Reader` on the subscription for backend identities only.
- `Cognitive Services OpenAI User` on `lab-ai-demo/aisdgkwm01` for backend identities only.
- ACA and Application Insights diagnostic settings.

Use placeholder bootstrap images until application images exist. Never grant the
frontend Cost Management or Foundry access.

- [ ] **Step 4: Run script validation without provisioning**

Run: `shellcheck infra/scripts/*.sh && bats infra/tests/provisioning.bats`

Expected: all checks pass.

- [ ] **Step 5: Commit**

```bash
git add infra/scripts infra/tests
git commit -m "feat: provision shared and isolated ACA infrastructure"
```

### Task 13: Configure Front Door Private Origins, Alerts, Deployment, and Verification

**Files:**
- Create: `infra/scripts/configure-frontdoor.sh`
- Create: `infra/scripts/deploy.sh`
- Create: `infra/scripts/verify.sh`
- Test: `infra/tests/frontdoor.bats`
- Test: `infra/tests/deploy.bats`

- [ ] **Step 1: Write failing route and digest tests**

Test that each Front Door endpoint has a frontend `/*` route and higher-priority
backend `/api/*` route, Private Link targets the correct managed environment, no
WAF policy exists, and deploy rejects mutable tags or non-`sha256:` digests.

- [ ] **Step 2: Implement Front Door and Private Link configuration**

Create environment-specific frontend/backend origin groups, health probes,
private origins, and routes. Approve only pending Private Link requests whose
description, profile resource ID, and environment match expected values.

- [ ] **Step 3: Implement alerts and diagnostics**

Create alerts for backend error rate, P95 request duration, failed dependencies,
ACA replica restarts, and missing post-deployment telemetry. Send Front Door
access and health-probe logs to both workspaces using environment-specific
diagnostic settings or duplicated destinations where the category supports it.

- [ ] **Step 4: Implement digest-only deploy and verification**

`deploy.sh` accepts environment plus two `sha256:` digests, updates both apps,
waits for healthy revisions, and shifts traffic only after readiness passes.
`verify.sh` checks identities, roles, image digests, Front Door routes, Private
Link state, health, diagnostics, and fresh Application Insights telemetry.

- [ ] **Step 5: Run all infrastructure tests**

Run:

```bash
shellcheck infra/scripts/*.sh
bats infra/tests
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add infra/scripts infra/tests
git commit -m "feat: configure Front Door deployment and monitoring"
```

## Phase 5: GitHub Governance and Delivery

### Task 14: Add CI, CodeQL, Dependency, and Infrastructure Workflows

**Files:**
- Create: `.github/dependabot.yml`
- Create: `.github/workflows/ci.yml`
- Create: `.github/workflows/codeql.yml`
- Create: `.github/workflows/infra.yml`
- Create: `.github/actionlint.yaml`

- [ ] **Step 1: Add workflow validation first**

Install and run `actionlint` against an intentionally incomplete workflow to
verify the validation command catches missing jobs.

- [ ] **Step 2: Implement `ci.yml`**

Trigger on PRs to `staging` and `main`. Use least-privilege `contents: read`.
Run frontend lint/test/build, backend Ruff/mypy/pytest, ShellCheck/Bats, Docker
builds, dependency audits, and upload test reports. Name stable required checks:
`frontend`, `backend`, `infrastructure`, and `container-build`.

- [ ] **Step 3: Implement CodeQL and Dependabot**

CodeQL scans `javascript-typescript`, `python`, and workflow Actions on PRs and
protected branches. Dependabot opens weekly grouped updates for npm, pip/uv,
Docker, and GitHub Actions against `staging`.

- [ ] **Step 4: Implement `infra.yml`**

Use `workflow_dispatch` with `plan` (`preflight`, `shared`, `staging`,
`production`, `verify`) and GitHub Environment approval. Authenticate with
`azure/login@v2`, explicit client/tenant/subscription IDs, and `id-token: write`.
Run only the corresponding Azure CLI script. Never use `creds:` or registry
passwords.

- [ ] **Step 5: Validate workflows locally**

Run:

```bash
actionlint .github/workflows/*.yml
yamllint .github/workflows .github/dependabot.yml
```

Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add .github
git commit -m "ci: add quality security and infrastructure workflows"
```

### Task 15: Implement Staging Build, Deploy, Test, and Promotion PR

**Files:**
- Create: `.github/workflows/deploy-staging.yml`
- Create: `.github/workflows/promote.yml`
- Create: `infra/scripts/resolve-digests.sh`
- Test: `infra/tests/resolve-digests.bats`

- [ ] **Step 1: Write failing immutable-digest tests**

Test that resolving tag `git-ec36640` returns two `sha256:` values, rejects an
image whose `org.opencontainers.image.revision` label differs from the staging
commit, and fails when either image is missing.

- [ ] **Step 2: Implement staging build and deploy**

On push to `staging`, use `az acr build` to build frontend and backend with tag
`git-${GITHUB_SHA}` and OCI revision labels. Resolve immutable digests, call
`deploy.sh staging`, then run health, live API, Playwright, route, Private Link,
and telemetry checks. Concurrency group `staging` cancels superseded runs.

- [ ] **Step 3: Implement automatic promotion PR**

`promote.yml` runs only after successful `deploy-staging.yml`. Use:

```bash
gh pr create \
  --base main \
  --head staging \
  --title "Promote staging to production" \
  --body "Staging commit $GITHUB_SHA passed live integration, E2E, and telemetry checks."
```

If an open `staging` to `main` PR exists, update its body instead. Grant only
`contents: read` and `pull-requests: write`.

- [ ] **Step 4: Validate workflows and resolver tests**

Run: `actionlint .github/workflows/*.yml && bats infra/tests/resolve-digests.bats`

Expected: all checks pass.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows infra/scripts/resolve-digests.sh infra/tests/resolve-digests.bats
git commit -m "ci: deploy and validate staging before promotion"
```

### Task 16: Implement Production Promotion and Repository Rules

**Files:**
- Create: `.github/workflows/deploy-production.yml`
- Create: `infra/scripts/configure-github.sh`
- Create: `docs/workshop-runbook.md`
- Modify: `README.md`
- Test: `infra/tests/github-rules.bats`

- [ ] **Step 1: Write failing promotion-parent and ruleset tests**

Require production merge commits to have `staging` as second parent, derive the
tested staging SHA with `git rev-parse HEAD^2`, and reject squash/rebase commits.
Test rulesets require PRs, CodeQL high-or-higher, Copilot review, named CI checks,
blocked deletion/force push, and no linear-history requirement.

- [ ] **Step 2: Implement production deployment**

Trigger only on push to `main`, bind to GitHub Environment `production`, and use
production OIDC identity. Resolve ACR digests from the second-parent staging SHA,
verify OCI revision labels, deploy both digests without rebuilding, run smoke and
telemetry checks, then write a GitHub deployment summary.

- [ ] **Step 3: Implement repository/environment governance script**

Use `gh api` idempotently to configure:

- `staging` and `main` rulesets.
- Required status checks after their first successful run.
- Required Copilot review and CodeQL high-or-higher gate.
- GitHub Environments `staging` and `production`.
- Production required reviewers and branch restriction to `main`.
- Merge commits enabled; squash and rebase disabled for promotion provenance.

Do not weaken the existing protection shown in the workshop screenshots.

- [ ] **Step 4: Write the workshop runbook**

Document prerequisites, one-time bootstrap, feature-to-staging PR, Copilot review,
CodeQL gate, staging deployment/test evidence, automatic promotion PR, human
browser-login acceptance check, production approval, deployment verification,
Application Insights queries, troubleshooting, and teardown commands.

- [ ] **Step 5: Run complete GitHub-hosted verification**

Run in the CI workflow, not on the workshop laptop:

```bash
cd backend && uv run ruff check . && uv run mypy src && uv run pytest --cov=cost_copilot
cd ../frontend && npm ci && npm run lint && npm test -- --run && npm run build
cd .. && shellcheck infra/scripts/*.sh && bats infra/tests
actionlint .github/workflows/*.yml
docker compose build
git diff --check
```

Expected: every command exits `0`.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/deploy-production.yml infra/scripts/configure-github.sh infra/tests docs/workshop-runbook.md README.md
git commit -m "ci: promote tested images to production"
```

## Phase 6: Controlled Provisioning and Release

### Task 17: Provision, Deploy, and Verify the Live Workshop

**Files:**
- Modify only if validation exposes defects in the files owned by Tasks 11-16.

- [ ] **Step 1: Run the read-only preflight under the lab Azure CLI account**

Run:

```bash
az account show --query '{id:id,tenantId:tenantId,user:user.name}' -o json
bash infra/scripts/preflight.sh
```

Expected: subscription `439cf6ec-8907-40ee-bae2-7efd9656cd09`, tenant
`a1571616-cb5c-4d81-93ab-83c3856d83f2`, and `READY`.

- [ ] **Step 2: Execute and verify the one-time trust bootstrap**

Run: `bash infra/scripts/bootstrap-oidc.sh`

Expected: app registrations, identities, federated credentials, role assignments,
and GitHub variables are created or reported unchanged; no secret is printed.

- [ ] **Step 3: Run infrastructure through GitHub Actions**

Run:

```bash
gh workflow run infra.yml -f plan=shared
gh workflow run infra.yml -f plan=staging
gh workflow run infra.yml -f plan=production
```

Wait for each run with `gh run watch --exit-status`. Expected: all runs succeed
after required approvals.

- [ ] **Step 4: Exercise the feature-to-staging delivery path**

Push the implementation feature branch, open a PR to `staging`, and require all
CI, CodeQL, and Copilot review gates. Merge only when green. Confirm staging build,
deployment, live tests, and telemetry pass and the promotion PR is created.

- [ ] **Step 5: Perform human staging acceptance**

Open the staging Front Door URL, sign in with a workshop-group account, verify
live summary/trend/breakdown data, ask a cost question, click an evidence action,
and confirm correlated traces appear only in staging Application Insights.

- [ ] **Step 6: Promote and verify production**

Approve and merge the `staging` to `main` PR with a merge commit. Approve the
production environment deployment. Verify both production apps use the exact ACR
digests tested in staging, Front Door private routes are healthy, and production
telemetry lands only in production Application Insights.

- [ ] **Step 7: Record release evidence**

Add the staging run URL, promotion PR URL, production run URL, image digests,
Front Door endpoints, and sanitized Application Insights query screenshots to the
workshop runbook. Do not commit tenant tokens or raw subscription cost data.

## Final Acceptance Matrix

| Requirement | Implemented By | Verification |
| --- | --- | --- |
| Live Azure cost data | Tasks 3, 17 | Cost APIs and human staging acceptance |
| GPT-5.4-mini grounded chat | Tasks 4, 8 | Contract tests and evidence click |
| Frontend/backend separated | Tasks 9, 12 | Four ACA resources verified |
| Staging before production | Tasks 15-17 | Promotion PR and workflow history |
| Test before `main` | Tasks 10, 15 | Live API, UI, route, telemetry gates |
| Managed identity | Tasks 2-4, 11-13 | Role and secret scans |
| Front Door without WAF | Tasks 13, 17 | Route/private-link/no-WAF checks |
| Azure Monitor/App Insights | Tasks 5, 8, 12-13 | Fresh correlated telemetry |
| Azure CLI infrastructure | Tasks 11-13 | Idempotency tests and workflow rerun |
| Code scanning/Copilot review | Tasks 14, 16 | Ruleset and PR checks |
| Immutable production promotion | Tasks 15-17 | Matching ACR digests and OCI labels |

## Official References

- [Cost Management Query API](https://learn.microsoft.com/rest/api/cost-management/query)
- [Assign access to Cost Management data](https://learn.microsoft.com/azure/cost-management-billing/costs/assign-access-acm-data)
- [Foundry Responses API](https://learn.microsoft.com/azure/foundry/foundry-models/how-to/generate-responses)
- [Azure OpenAI keyless authentication](https://learn.microsoft.com/azure/developer/ai/keyless-connections)
- [MSAL React hooks and token acquisition](https://learn.microsoft.com/entra/msal/javascript/react/hooks)
- [Azure Monitor OpenTelemetry for Python](https://learn.microsoft.com/azure/azure-monitor/app/opentelemetry-enable)
- [Front Door Premium and private ACA origins](https://learn.microsoft.com/azure/container-apps/front-door-custom-virtual-network-private-link)
- [Container Apps GitHub Actions deployment](https://learn.microsoft.com/azure/container-apps/github-actions)
- [GitHub Actions OIDC for Azure](https://learn.microsoft.com/azure/developer/github/connect-from-azure)