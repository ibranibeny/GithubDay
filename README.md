# Azure Cost Copilot

Chat with your Azure spend. Azure Cost Copilot pairs a **Microsoft Foundry
(GPT‑5) chatbot** with an **Azure Cost Analysis dashboard**: ask a plain‑English
question ("why did compute jump last week?") and get an answer grounded in the
same cost figures the charts render, with the evidence attached.

## What it is

- **Backend** — a FastAPI service that validates Entra ID access tokens
  (`Cost.Read` app role), queries Azure **Cost Management**, and calls a Foundry
  model to answer questions grounded in that data. Its answers cite the exact
  metrics they used.
- **Frontend** — a React (Vite) single‑page app: an MSAL sign‑in, a cost
  dashboard (ECharts), and a chat panel. It reads back a correlation id for every
  request so a trace can be followed end to end.

## Architecture

```
            Browser (Entra ID sign-in, MSAL)
                     │  https
              Azure Front Door (Premium)
        /api/*, /health/*  │        │  /*
                 ┌─────────┘        └─────────┐
      backend Container App            frontend Container App
      (FastAPI, user-assigned MI)      (nginx-served SPA)
             │                                  
   Cost Management  ── Foundry (GPT-5, eastus2)  
             └── Application Insights / Azure Monitor / Log Analytics
```

- **Front Door Premium** fronts **two Azure Container Apps environments**,
  **staging** and **production**, both in **`indonesiacentral`**, reached over
  **private link** (the apps have internal ingress only). Routing is by longest
  path prefix: `/api/*` and `/health/*` → backend, everything else → the SPA.
- Each app runs as its own **user‑assigned managed identity** (least privilege:
  only the backend holds *Cost Management Reader* and *Cognitive Services OpenAI
  User*). Users authenticate with **Entra ID**; the backend enforces the
  `Cost.Read` role on every request.
- **Application Insights / Azure Monitor / Log Analytics** capture telemetry,
  and diagnostic settings + alerts are provisioned per environment.
- The **Foundry** model deployment lives in **`eastus2`**.

## Repository layout

```
backend/     FastAPI service (uv-managed, src/cost_copilot), Dockerfile
frontend/    React + Vite SPA, Playwright config, nginx image
infra/        config/*.env, scripts/*.sh (provision, deploy, verify, governance), tests/*.bats
tests/e2e/    Playwright end-to-end suites (dashboard, auth redirect, live-api)
.github/      CI, CodeQL, and the staging/production/promote/infra workflows
docs/         operator runbook and design/plan notes
```

## Run it locally

**Backend** (Python 3.13, [uv](https://docs.astral.sh/uv/)):

```bash
cd backend
uv sync                 # install the locked dependency set
uv run ruff check .     # lint
uv run pytest           # unit + contract tests (integration is opt-in: -m integration)
uv run uvicorn cost_copilot.main:app --reload   # serve on :8000
```

Copy `.env.example` to `backend/.env` and fill in the tenant, subscription,
`ENTRA_API_CLIENT_ID`, and `FOUNDRY_ENDPOINT` before serving.

**Frontend** (Node ≥ 22.12; CI installs via `npm ci` and runs the tool binaries
directly):

```bash
cd frontend
npm ci
npm run dev             # Vite dev server
npm run lint && npm test && npm run build
```

For UI work without Entra sign‑in or a backend, use the **fixture preview
harness** — `frontend/preview.html` renders the dashboard against fixtures
(`vite` serves it; it is never emitted by `vite build`).

**Both together** (containers):

```bash
docker compose up --build   # API on :8000, web on :8080
```

## CI/CD flow

```
feature PR ──▶ staging ──▶ (auto) staging deploy + E2E ──▶ promotion PR ──▶ main ──▶ production deploy
   CI + CodeQL + Copilot review        verify.sh + Playwright      human approval    verify + smoke + telemetry
```

Every PR runs four required checks (`frontend`, `backend`, `infrastructure`,
`container-build`), CodeQL, and a Copilot review. Merging to `staging`
auto‑deploys and runs the E2E suites; a green deploy opens a `staging → main`
**merge** PR. Merging that (with production reviewer approval) promotes the
**exact images** staging tested — production never rebuilds; it reads the tested
commit from the merge's second parent. All Azure access is **OIDC only** — no
client secrets or registry passwords anywhere.

## Operating it

See **[docs/workshop-runbook.md](docs/workshop-runbook.md)** for the end‑to‑end
operator guide: prerequisites, the one‑time OIDC bootstrap, provisioning,
governance, the ship flow, verification, Application Insights KQL,
troubleshooting, and teardown.