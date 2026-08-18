import { expect, test } from "@playwright/test";

/**
 * The interactive-login boundary.
 *
 * A GitHub-hosted runner cannot complete a human Microsoft Entra ID sign-in: multi-factor
 * authentication and Conditional Access are interactive by design, and automating them would
 * mean weakening the very controls the tenant relies on. So the automated gate stops exactly
 * where a human begins. This spec proves the anonymous path — that an unauthenticated visitor
 * is sent to the configured tenant's authorization endpoint with the right client and scope —
 * and `live-api.spec.ts` proves every authenticated API behaviour using the pipeline's OIDC
 * federated identity. The one thing neither can prove, a real person signing in through the
 * browser and landing on the dashboard, is a manual acceptance step in the workshop runbook and
 * must be performed before a production approval is given.
 *
 * Nothing here leaves the runner: the authorization request is intercepted and aborted, so the
 * external navigation is asserted on and never completed.
 */

// Well-formed but deliberately fictitious identifiers. MSAL ships hardcoded endpoint metadata
// for login.microsoftonline.com, so it templates the authority from these values without a
// tenant lookup; the test therefore needs no real directory and makes no discovery call.
const TENANT_ID = "11111111-2222-3333-4444-555555555555";
const SPA_CLIENT_ID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
const API_CLIENT_ID = "99999999-8888-7777-6666-555555555555";

const APP_CONFIG = {
  environment: "e2e",
  tenantId: TENANT_ID,
  spaClientId: SPA_CLIENT_ID,
  apiClientId: API_CLIENT_ID,
  apiBaseUrl: "http://localhost:8000",
};

const AUTHORIZE_URL = /^https:\/\/login\.microsoftonline\.com\/[^/]+\/oauth2\/v2\.0\/authorize/;

test("sends an anonymous visitor to the configured tenant authority", async ({ page }) => {
  // Two injections, because index.html loads /config.js as a classic script in <head>: an init
  // script alone would be overwritten by the checked-in development file, whose identifiers are
  // intentionally blank. Replacing the response is what makes the configuration stick; the init
  // script keeps the spec working against a build that ships no config.js at all.
  await page.addInitScript((config) => {
    window.__APP_CONFIG__ = config;
  }, APP_CONFIG);
  await page.route("**/config.js", (route) =>
    route.fulfill({
      status: 200,
      contentType: "text/javascript",
      body: `window.__APP_CONFIG__ = ${JSON.stringify(APP_CONFIG)};`,
    }),
  );

  // The sign-in navigation is answered locally, so the browser never reaches Entra ID.
  await page.route(AUTHORIZE_URL, (route) => route.abort());

  const authorizeRequest = page.waitForRequest(AUTHORIZE_URL);
  // "commit" and not "load": the redirect is started from the app's first render, and waiting
  // for load would race the navigation this test is about.
  await page.goto("/", { waitUntil: "commit" });

  const authorize = new URL((await authorizeRequest).url());

  expect(authorize.host).toBe("login.microsoftonline.com");
  expect(authorize.pathname).toContain(TENANT_ID);
  expect(authorize.pathname).toBe(`/${TENANT_ID}/oauth2/v2.0/authorize`);
  expect(authorize.searchParams.get("client_id")).toBe(SPA_CLIENT_ID);
  expect(authorize.searchParams.get("response_type")).toBe("code");
  expect(authorize.searchParams.get("scope")).toContain(`api://${API_CLIENT_ID}/Cost.Read`);
  // Authorization code flow with PKCE: a missing challenge would mean a code interceptable in
  // transit, which is the whole reason a SPA may not use an implicit grant.
  expect(authorize.searchParams.get("code_challenge")).toBeTruthy();
  expect(authorize.searchParams.get("code_challenge_method")).toBe("S256");

  // The dashboard is withheld until an account exists, so the aborted redirect leaves the gate.
  await expect(page.getByRole("status")).toContainText("Signing in");
  await expect(page.locator(".page__title")).toHaveCount(0);
});
