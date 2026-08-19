# Azure Cost Copilot — workshop runbook

A practical, skimmable operator guide: from an empty subscription to a verified
production deployment, and back to a clean teardown. Commands are copy-pasteable.
Run them from the repository root on the workshop laptop (WSL bash, with the
Windows `az`/`gh`/`docker` reachable through interop).

> Golden rule: **one** step runs locally under your own login —
> `bootstrap-oidc.sh`. Everything after it runs in GitHub Actions with OIDC. If
> you find yourself running `deploy.sh` or `provision-*.sh` by hand, stop and use
> the workflow instead.

---

## 1. Prerequisites

| Need | Check |
| --- | --- |
| Azure CLI ≥ 2.60 | `az version` |
| GitHub CLI ≥ 2.55, authenticated | `gh --version` && `gh auth status` |
| Docker (for local compose only) | `docker version` |
| `jq` | `jq --version` |

Access you must hold **before** bootstrap:

- **Owner** (or Contributor + User Access Administrator) on subscription
  `439cf6ec-8907-40ee-bae2-7efd9656cd09`, tenant
  `a1571616-cb5c-4d81-93ab-83c3856d83f2`.
- Permission to create Entra ID **app registrations** and **app-role
  assignments** (Application Administrator, or Global Administrator).
- **Admin** on the `ibranibeny/GithubDay` repository (to write rulesets,
  environments and variables).
- The object ID of the Entra ID group whose members may read cost data:
  export it as `WORKSHOP_GROUP_OBJECT_ID`.

```bash
az login                     # interactive; device code is fine
az account set --subscription 439cf6ec-8907-40ee-bae2-7efd9656cd09
export WORKSHOP_GROUP_OBJECT_ID=<object-id-of-the-workshop-entra-group>
```

---

## 2. One-time OIDC bootstrap (the only non-OIDC step)

`bootstrap-oidc.sh` is the sole step that **cannot** use OIDC, because it is what
*creates* the OIDC trust — bootstrapping OIDC with OIDC is impossible. It runs
under your interactive `az login` plus an authenticated `gh`. It is idempotent
and prints only identifiers — never a secret, password, or token.

```bash
bash infra/scripts/bootstrap-oidc.sh
```

What it creates:

- Entra app registrations **Azure Cost Copilot API** and **Azure Cost Copilot
  SPA**, the `Cost.Read` app role and delegated scope, and SPA pre-authorization.
- User-assigned managed identities for the **staging**, **production** and
  **deploy-test** deployers, each with the federated credentials GitHub presents
  (`environment:staging`, `ref:refs/heads/staging`, `environment:production`,
  `ref:refs/heads/main`, `pull_request`).
- `Cost.Read` **app-role assignments** to the workshop group *and* to the
  deploy-test identity's service principal. The latter is what lets the live-api
  E2E suite's app-only token carry `roles: ["Cost.Read"]`, which the backend
  requires.
- GitHub repository/environment **variables** (`AZURE_CLIENT_ID`,
  `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, the Entra client IDs, resource
  names).

> The SPA redirect URIs need the Front Door hostnames, which do not exist yet.
> Provision first (step 4), then **re-run** bootstrap with
> `STAGING_FRONTDOOR_HOSTNAME=… PRODUCTION_FRONTDOOR_HOSTNAME=…` set to register
> them.

---

## 3. Repository governance

Apply branch, merge and environment governance (idempotent; only adds/tightens):

```bash
# optionally: export PRODUCTION_REVIEWERS="alice,bob"   # GitHub user logins
bash infra/scripts/configure-github.sh
```

This creates rulesets on `staging` and `main` that require a PR, the four CI
checks (`frontend`, `backend`, `infrastructure`, `container-build`), CodeQL at
**high or higher**, and a **Copilot review**, and block deletion and
force-pushes. Merge commits stay enabled while squash and rebase are disabled, so
promotion keeps a real second parent. Production gets required reviewers (when
`PRODUCTION_REVIEWERS` is supplied) and a deployment branch policy pinned to
`main`.

> Required status checks only start *blocking* after each check has reported once
> on the branch; the contexts are recorded immediately but "stick" after the
> first CI run.

---

## 4. Provision infrastructure

Provisioning mutates and bills real resources, so it is **manually dispatched**
via the **Infrastructure** workflow (`.github/workflows/infra.yml`), OIDC only.
Run the plans in order from the Actions tab:

| Order | Plan | Environment gate |
| --- | --- | --- |
| 1 | `preflight` | staging |
| 2 | `shared` | staging |
| 3 | `staging` | staging |
| 4 | `production` | **production reviewers approve** |

`preflight` checks config consistency; `shared` creates the registry and Front
Door profile; `staging`/`production` create the VNet, Container Apps environment,
the two container apps, identities, Log Analytics/App Insights, and wire the
Front Door routes/private links. Approve the production run when prompted.

Then re-run `bootstrap-oidc.sh` (step 2) with the two Front Door hostnames to
register the SPA redirect URIs.

---

## 5. Ship a change: feature → staging → production

The everyday flow — no manual Azure commands anywhere:

1. **Feature PR → `staging`.** Open a PR targeting `staging`. CI runs the four
   required checks; CodeQL and **Copilot** review it. The PR cannot merge until
   they pass and a reviewer approves.
2. **Merge to `staging` → auto-deploy.** `deploy-staging.yml` builds both images
   in the shared registry (tagged `git-<sha>` with the commit stamped as an OCI
   label), resolves them to immutable digests **and verifies the label matches
   the commit**, deploys by digest with a health gate + traffic shift, runs
   `verify.sh`, then the Playwright + live-api E2E suites. Evidence: the
   Playwright report artifact and the job summary.
3. **Automatic promotion PR.** On a green staging deploy, `promote.yml` opens (or
   refreshes) a long-lived `staging → main` **merge** PR describing the exact
   tested commit. It never merges for you.
4. **Human acceptance check (browser).** Before approving, open the **staging**
   Front Door URL in a browser, sign in with a workshop-group account, and
   confirm the chat answers and the cost dashboard render. This is the one check
   automation cannot do for you.
5. **Approve + merge the promotion PR.** Branch protection on `main` and the
   `production` environment reviewers apply here.
6. **Production deploy.** Merging fires `deploy-production.yml`. It derives the
   tested staging commit from `HEAD^2` (**refusing** if the merge was squashed or
   rebased away), re-resolves the *same* `git-<sha>` images to digests, re-checks
   their provenance, deploys by digest, runs `verify.sh production`, a live smoke
   + telemetry check, and writes a deployment summary (staging SHA, both digests,
   verify result, request count).

---

## 6. Verify a deployment

The workflows run this for you; to check by hand from an OIDC-authenticated
context (or locally after `az login`):

```bash
bash infra/scripts/verify.sh production
```

It asserts: both apps carry their own user-assigned identity; the backend
identity holds **Cost Management Reader** + **Cognitive Services OpenAI User**
and the frontend holds neither; images are pinned by digest; Front Door routes
`/api/*` and `/health/*` to the backend and `/*` to the SPA; private-link
connections are Approved; the endpoint serves `/health/live` (200) and the SPA;
diagnostics exist; and fresh telemetry arrived. The production deploy job's
**summary** repeats the key facts (staging SHA, digests, telemetry count).

---

## 7. Application Insights KQL

Open the environment's Application Insights resource → **Logs** and run:

**Request failures (last hour)**

```kusto
requests
| where timestamp > ago(1h)
| where success == false
| summarize failures = count() by name, resultCode
| order by failures desc
```

**P95 latency by route (last 6h)**

```kusto
requests
| where timestamp > ago(6h)
| summarize p95_ms = percentile(duration, 95) by name, bin(timestamp, 15m)
| order by timestamp asc
```

**Dependency failures (Cost Management / Foundry, last hour)**

```kusto
dependencies
| where timestamp > ago(1h)
| where success == false
| summarize failures = count() by target, name, resultCode
| order by failures desc
```

**Trace one request by correlation id** — copy the `x-correlation-id` response
header the SPA surfaces, then:

```kusto
let cid = "<correlation-id>";
union requests, dependencies, traces, exceptions
| where timestamp > ago(1d)
| where operation_Id == cid or customDimensions["correlationId"] == cid
| project timestamp, itemType, name, resultCode, success, message, operation_Id
| order by timestamp asc
```

---

## 8. Troubleshooting (known live-verify gotchas)

- **`az afd` private-link flag shape.** `configure-frontdoor.sh` enables the
  origin private link; if a CLI/extension version rejects the flag, check the
  `--enable-private-link` / `--private-link-*` argument shape for your installed
  `az afd origin` version and update the call — the resource IDs are correct.
- **Cost query `--body @file` under WSL.** When `az` is the Windows binary
  reached through WSL, inline JSON quoting is unreliable; request bodies are
  written to a temp file and passed as `--body @<path>` translated with
  `wslpath` (see `az_body_file`/`az_path` in `lib.sh`). If a cost query 400s on a
  malformed body, confirm the file path was translated for Windows `az`.
- **Front Door probe protocol.** Probes default to **HTTPS**
  (`AFD_PROBE_PROTOCOL=Https`). If a live origin marks unhealthy on the HTTPS
  probe's certificate-name check, set `AFD_PROBE_PROTOCOL=Http` in the env config
  and re-run `configure-frontdoor.sh`.
- **`HEAD^2` refusal on production deploy.** If `deploy-production.yml` fails at
  "Derive the tested staging commit", the merge to `main` was a squash/rebase or
  a direct push. Re-merge the `staging → main` PR as a **merge commit** (squash
  and rebase are disabled precisely to prevent this).
- **First required-check merge is blocked.** A required status check that has
  never reported yet blocks merges until its first run; push a trivial commit or
  re-run CI once so each context reports.

---

## 9. Teardown

Removes everything the workshop created. Destructive — double-check the
subscription first.

```bash
# 1. Resource groups (environments + shared).
az group delete --name rg-cost-copilot-production --yes --no-wait
az group delete --name rg-cost-copilot-staging    --yes --no-wait
az group delete --name rg-cost-copilot-shared     --yes --no-wait

# 2. Subscription role assignments held by the deployment identities.
for name in id-cost-copilot-deploy-staging id-cost-copilot-deploy-production id-cost-copilot-deploy-test; do
  pid="$(az identity show --name "$name" --resource-group rg-cost-copilot-shared \
    --query principalId -o tsv 2>/dev/null | tr -d '\r' || true)"
  [ -n "$pid" ] && az role assignment delete --assignee-object-id "$pid" \
    --scope "/subscriptions/439cf6ec-8907-40ee-bae2-7efd9656cd09" || true
done

# 3. Entra app registrations (deletes their service principals and app roles).
for app in "Azure Cost Copilot API" "Azure Cost Copilot SPA"; do
  appid="$(az ad app list --display-name "$app" --query '[0].appId' -o tsv | tr -d '\r')"
  [ -n "$appid" ] && az ad app delete --id "$appid" || true
done
```

Managed identities and their federated credentials are deleted with
`rg-cost-copilot-shared` in step 1. Finally, remove the repository rulesets and
environments from **Settings → Rules / Environments** if you want the repo
returned to an ungoverned state.
