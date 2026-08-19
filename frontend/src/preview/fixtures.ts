import type { ChatResponse, CostFilter, CostGrouping } from "../api/contracts";
import type { ChatGateway } from "../features/chat/useCostChat";
import type {
  BreakdownItem,
  CostBreakdownResponse,
  CostGateway,
  CostSummaryResponse,
  CostTrendResponse,
  TrendPoint,
} from "../features/dashboard/useCostData";

/**
 * Fixtures for the development preview only. Nothing here is imported by the application entry,
 * so the production bundle never sees these names or numbers.
 *
 * The month is deliberately over budget: it is the only way to see the over-budget area, the
 * forecast, and the forecast overage layers at the same time.
 */

const MONTH = "2026-08";
const FRESHNESS = "2026-08-19";
const ACTUAL_DAYS = 19;
const CURRENCY = "USD";
const RERATING =
  "Costs in the current billing period are preliminary and can be rerated until the invoice is final.";

export const PREVIEW_FILTER: CostFilter = {
  from: `${MONTH}-01`,
  to: `${MONTH}-31`,
  metric: "ActualCost",
  grouping: "ServiceName",
};

function round2(value: number): number {
  return Math.round(value * 100) / 100;
}

// August 2026 opens on a Saturday, so weekend dips land on the 1st, 2nd, 8th, 9th, 15th and 16th.
const WEEKEND_DAYS = new Set([1, 2, 8, 9, 15, 16]);

const POINTS: TrendPoint[] = Array.from({ length: ACTUAL_DAYS }, (_unused, index) => {
  const day = index + 1;
  const weekday = !WEEKEND_DAYS.has(day);
  const drift = day * 3.15; // steady growth as the workshop environment fills up
  const base = weekday ? 288.4 : 191.7;
  const wobble = ((day * 37) % 11) - 5; // deterministic, not random: screenshots must repeat
  return {
    usageDate: `${MONTH}-${String(day).padStart(2, "0")}`,
    amount: round2(base + drift + wobble),
  };
});

const TOTAL = round2(POINTS.reduce((sum, point) => sum + point.amount, 0));
const PREVIOUS_TOTAL = 4712.33;

const SUMMARY: CostSummaryResponse = {
  generatedAt: "2026-08-20T06:12:00Z",
  dataFreshness: FRESHNESS,
  currency: CURRENCY,
  reratingNotice: RERATING,
  total: TOTAL,
  previousTotal: PREVIOUS_TOTAL,
  change: {
    amount: round2(TOTAL - PREVIOUS_TOTAL),
    percentage: round2(((TOTAL - PREVIOUS_TOTAL) / PREVIOUS_TOTAL) * 100),
  },
  forecast: round2((TOTAL / ACTUAL_DAYS) * 31 * 1.02),
  topDriver: { name: "Azure App Service", amount: round2(TOTAL * 0.2537) },
};

const TREND: CostTrendResponse = {
  generatedAt: SUMMARY.generatedAt,
  dataFreshness: FRESHNESS,
  currency: CURRENCY,
  reratingNotice: RERATING,
  points: POINTS,
};

function rank(shares: [string, number][]): { items: BreakdownItem[]; otherAmount: number } {
  const items = shares.map(([name, share]) => ({
    name,
    amount: round2(TOTAL * share),
    percentage: round2(share * 100),
  }));
  const claimed = items.reduce((sum, item) => sum + item.amount, 0);
  return { items, otherAmount: round2(TOTAL - claimed) };
}

const BREAKDOWNS: Record<CostGrouping, { items: BreakdownItem[]; otherAmount: number }> = {
  ServiceName: rank([
    ["Azure App Service", 0.2537],
    ["Azure Cosmos DB", 0.2055],
    ["Application Gateway", 0.1602],
    ["API Management", 0.1377],
    ["Azure Cognitive Search", 0.0959],
    ["Azure Container Apps", 0.0794],
    ["Azure Bastion", 0.0423],
  ]),
  ResourceGroupName: rank([
    ["rg-workshop-prod", 0.4221],
    ["rg-data-platform", 0.2376],
    ["rg-network-hub", 0.1779],
    ["rg-observability", 0.0885],
    ["rg-workshop-shared", 0.0564],
  ]),
  ResourceId: rank([
    ["app-costcopilot-api", 0.2144],
    ["cosmos-costcopilot-prod", 0.1908],
    ["agw-hub-prod", 0.1602],
    ["apim-workshop-prod", 0.1377],
    ["srch-workshop-prod", 0.0959],
    ["ca-costcopilot-web", 0.0794],
    ["bas-hub-prod", 0.0423],
  ]),
  Tag: rank([
    ["costCenter:1042", 0.4812],
    ["costCenter:2081", 0.3164],
    ["costCenter:untagged", 0.1502],
  ]),
};

export const previewGateway: CostGateway = {
  fetchSummary: () => Promise.resolve(SUMMARY),
  fetchTrend: () => Promise.resolve(TREND),
  fetchBreakdown: (_filter, grouping): Promise<CostBreakdownResponse> =>
    Promise.resolve({
      generatedAt: SUMMARY.generatedAt,
      dataFreshness: FRESHNESS,
      currency: CURRENCY,
      reratingNotice: RERATING,
      grouping,
      total: TOTAL,
      ...BREAKDOWNS[grouping],
    }),
};

// A fixed, grounded reply so the preview can demonstrate the assistant without a backend or a
// model. The figures match the breakdown fixtures above (App Service 25.37%, Cosmos DB 20.55% of
// TOTAL), so evidence a reader applies lands on the same numbers the donuts draw.
const CHAT_REPLY: ChatResponse = {
  answer:
    "August is tracking to $5,502.90 through the 19th \u2014 16.8% above July and $1,502.90 over the " +
    "$4,000 budget. Azure App Service is the largest driver at $1,396.09 (25.4%), with Azure Cosmos " +
    "DB next at $1,130.85. The accumulated line crossed the budget around 13 August.",
  evidence: [
    {
      metric: "ActualCost",
      dimension: "Azure App Service",
      periodStart: "2026-08-01",
      periodEnd: "2026-08-19",
      amount: 1396.09,
    },
    {
      metric: "ActualCost",
      dimension: "Azure Cosmos DB",
      periodStart: "2026-08-01",
      periodEnd: "2026-08-19",
      amount: 1130.85,
    },
  ],
  chartActions: [
    { kind: "highlight-series", grouping: "ServiceName", value: "Azure App Service" },
    { kind: "set-filter", grouping: "ResourceGroupName" },
    { kind: "set-filter", metric: "AmortizedCost" },
  ],
  explanationAvailable: true,
};

export const previewChatGateway: ChatGateway = {
  // A short delay exercises the pending/aria-busy state without making screenshots flaky.
  send: () => new Promise((resolve) => setTimeout(() => resolve(CHAT_REPLY), 250)),
};
