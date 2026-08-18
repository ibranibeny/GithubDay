import { expect, test, type APIRequestContext } from "@playwright/test";

import { getAccessToken } from "./helpers/token";

/**
 * The staging gate. This is the only suite that touches deployed infrastructure: it calls the
 * API through Front Door with a real Entra token, so it covers everything the browser specs
 * cannot — the token audience, the server-fixed subscription scope, currency consistency across
 * endpoints, correlation-id echo, and whether chat evidence matches the cost figures the same
 * deployment returns.
 *
 * It no-ops everywhere except the staging pipeline. `STAGING_BASE_URL` and `ENTRA_API_CLIENT_ID`
 * are set by that workflow, and the token comes from the ambient Azure CLI login, which on the
 * runner is the GitHub OIDC federated identity: no secret is stored and none is passed here.
 */

const STAGING_BASE_URL = process.env.STAGING_BASE_URL;
const ENTRA_API_CLIENT_ID = process.env.ENTRA_API_CLIENT_ID;
const CONFIGURED = Boolean(STAGING_BASE_URL && ENTRA_API_CLIENT_ID);

// Staging is billed in USD; a different code means the deployment queried the wrong scope.
const EXPECTED_CURRENCY = "USD";
// Grounded evidence is copied from the query result, so only floating-point noise is tolerated.
const AMOUNT_TOLERANCE = 0.01;

interface CostContext {
  currency: string | null;
}

interface CostSummary extends CostContext {
  total: number;
}

interface CostTrend extends CostContext {
  points: { usageDate: string; amount: number }[];
}

interface CostBreakdown extends CostContext {
  grouping: string;
  total: number;
  items: { name: string; amount: number; percentage: number }[];
  otherAmount: number;
}

interface Evidence {
  metric: string;
  dimension: string;
  periodStart: string;
  periodEnd: string;
  amount: number;
}

interface ChatResponse {
  answer: string;
  evidence: Evidence[];
  chartActions: unknown[];
  explanationAvailable: boolean;
}

function isoDay(value: Date): string {
  return value.toISOString().slice(0, 10);
}

const TODAY = new Date();
const WINDOW = {
  start: isoDay(new Date(Date.UTC(TODAY.getUTCFullYear(), TODAY.getUTCMonth(), 1))),
  end: isoDay(TODAY),
};

// Note what is absent: no subscription, resource group, or scope of any kind. The deployment
// pins the subscription in its own settings, which is the property the scope test below proves.
const QUERY = { ...WINDOW, metric: "ActualCost", grouping: "ServiceName" };

test.describe("staging API", () => {
  test.skip(
    !CONFIGURED,
    "STAGING_BASE_URL and ENTRA_API_CLIENT_ID are only set in the staging pipeline",
  );

  // Safe after the skip above; keeps the rest of the file free of non-null assertions.
  const baseUrl = STAGING_BASE_URL ?? "";
  let token = "";

  test.beforeAll(async () => {
    token = await getAccessToken(`api://${ENTRA_API_CLIENT_ID ?? ""}`);
  });

  test("answers liveness without a token", async ({ request }) => {
    const response = await request.get(`${baseUrl}/health/live`);
    expect(response.status()).toBe(200);
    expect(await response.json()).toEqual({ status: "alive" });
  });

  test("reports one currency across summary, trend, and breakdown", async ({ request }) => {
    const summary = await getJson<CostSummary>(request, "/api/costs/summary");
    const trend = await getJson<CostTrend>(request, "/api/costs/trend");
    const breakdown = await getJson<CostBreakdown>(request, "/api/costs/breakdown");

    expect(summary.currency).toBe(EXPECTED_CURRENCY);
    expect(trend.currency).toBe(EXPECTED_CURRENCY);
    expect(breakdown.currency).toBe(EXPECTED_CURRENCY);

    expect(Number.isFinite(summary.total)).toBe(true);
    expect(breakdown.grouping).toBe("ServiceName");
    // The ranked items plus the remainder are the same money the summary reports.
    const ranked = breakdown.items.reduce((sum, item) => sum + item.amount, 0);
    expect(ranked + breakdown.otherAmount).toBeCloseTo(breakdown.total, 2);
  });

  test("ignores a caller-supplied subscription: the scope is fixed server-side", async ({
    request,
  }) => {
    const scoped = await getJson<CostSummary>(request, "/api/costs/summary", {
      // A subscription the test identity has no reason to be able to read. If the API honoured
      // it, the total would move or the call would fail; an identical total proves it is inert.
      subscriptionId: "00000000-0000-0000-0000-000000000000",
      scope: "/subscriptions/00000000-0000-0000-0000-000000000000",
    });
    const unscoped = await getJson<CostSummary>(request, "/api/costs/summary");

    expect(scoped.total).toBeCloseTo(unscoped.total, 2);
    expect(scoped.currency).toBe(unscoped.currency);
  });

  test("rejects an unauthenticated cost request", async ({ request }) => {
    const response = await request.get(`${baseUrl}/api/costs/summary`, { params: QUERY });
    expect([401, 403]).toContain(response.status());
  });

  test("grounds chat evidence in the cost figures the same deployment returns", async ({
    request,
  }) => {
    const breakdown = await getJson<CostBreakdown>(request, "/api/costs/breakdown");
    const byName = new Map(breakdown.items.map((item) => [item.name, item.amount]));

    const correlationId = crypto.randomUUID();
    const response = await request.post(`${baseUrl}/api/chat`, {
      headers: {
        Authorization: `Bearer ${token}`,
        "x-correlation-id": correlationId,
      },
      // The wire shape is start/end, not the browser's from/to, and unknown fields are refused.
      data: {
        prompt: "Which service drove the most cost this period, and by how much?",
        filters: QUERY,
      },
    });

    expect(response.status(), whyItFailed("/api/chat", response.status())).toBe(200);
    expect(response.headers()["x-correlation-id"]).toBe(correlationId);

    const chat = (await response.json()) as ChatResponse;
    expect(typeof chat.answer).toBe("string");
    expect(Array.isArray(chat.evidence)).toBe(true);
    expect(typeof chat.explanationAvailable).toBe("boolean");

    for (const item of chat.evidence) {
      expect(item.metric).toBe(QUERY.metric);
      expect(Number.isFinite(item.amount)).toBe(true);
      expect(item.periodStart).toBe(WINDOW.start);
      expect(item.periodEnd).toBe(WINDOW.end);

      const queried = byName.get(item.dimension);
      // Evidence may cite a service outside the ranked head; only overlapping names are
      // comparable, and where they overlap the figures have to be the same money.
      if (queried !== undefined) {
        expect(Math.abs(item.amount - queried)).toBeLessThanOrEqual(AMOUNT_TOLERANCE);
      }
    }
  });

  async function getJson<T>(
    request: APIRequestContext,
    path: string,
    extraParams: Record<string, string> = {},
  ): Promise<T> {
    const correlationId = crypto.randomUUID();
    const response = await request.get(`${baseUrl}${path}`, {
      headers: {
        Authorization: `Bearer ${token}`,
        "x-correlation-id": correlationId,
      },
      params: { ...QUERY, ...extraParams },
    });

    expect(response.status(), whyItFailed(path, response.status())).toBe(200);
    // The id the caller sent comes back, so a support request can be traced end to end.
    expect(response.headers()["x-correlation-id"]).toBe(correlationId);
    return (await response.json()) as T;
  }
});

/** Response bodies can quote account data, so only the path and status reach a message. */
function whyItFailed(path: string, status: number): string {
  return `${path} should answer 200 (got ${status})`;
}
