import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { cleanup, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import type { CSSProperties } from "react";
import { afterEach, beforeEach, describe, expect, it, vi, type Mock } from "vitest";

import { ApiForbiddenError } from "../../api/client";
import type { CostFilter, CostGrouping } from "../../api/contracts";
import tokensCss from "../../styles/tokens.css?raw";
import { CostDashboard } from "./CostDashboard";
import { TREND_SERIES_IDS, buildTrendOption } from "./chartOptions";
import { KPI_BLOCK_HEIGHT, TREND_CHART_HEIGHT } from "./layout";
import {
  CostDataContext,
  buildCsvFileName,
  toCsv,
  type CostBreakdownResponse,
  type CostGateway,
  type CostSummaryResponse,
  type CostTrendResponse,
} from "./useCostData";

// ECharts measures and paints; jsdom does neither. The stub keeps the option object visible so
// layout and series wiring stay assertable, while the option itself is verified as pure data.
vi.mock("echarts-for-react", () => ({
  default: ({
    option,
    style,
  }: {
    option: { series?: { id?: string }[] };
    style?: CSSProperties;
  }) => (
    <div
      data-testid="echart"
      data-series={(option.series ?? []).map((series) => series.id ?? "").join(",")}
      style={style}
    />
  ),
}));

const FILTER: CostFilter = {
  from: "2026-08-01",
  to: "2026-08-31",
  metric: "ActualCost",
  grouping: "ServiceName",
};

const CONTEXT = {
  generatedAt: "2026-08-20T06:00:00Z",
  dataFreshness: "2026-08-19",
  currency: "USD",
  reratingNotice: "Costs in the current billing period are preliminary.",
};

const SUMMARY: CostSummaryResponse = {
  ...CONTEXT,
  total: 5210.42,
  previousTotal: 4890.1,
  change: { amount: 320.32, percentage: 6.55 },
  forecast: 8320.5,
  topDriver: { name: "Azure App Service", amount: 1620.4 },
};

const TREND: CostTrendResponse = {
  ...CONTEXT,
  points: [
    { usageDate: "2026-08-01", amount: 180.25 },
    { usageDate: "2026-08-02", amount: 210.5 },
    { usageDate: "2026-08-03", amount: 260.75 },
  ],
};

const BREAKDOWN_ITEMS: Record<CostGrouping, string[]> = {
  ServiceName: ["Azure App Service", "Azure Cosmos DB"],
  ResourceGroupName: ["rg-workshop-prod", "rg-network-hub"],
  ResourceId: ["apim-workshop-prod", "agw-hub-prod"],
  Tag: ["costCenter:1042", "costCenter:2081"],
};

function breakdownFor(grouping: CostGrouping): CostBreakdownResponse {
  const names = BREAKDOWN_ITEMS[grouping];
  return {
    ...CONTEXT,
    grouping,
    total: 5210.42,
    items: [
      { name: names[0], amount: 3100.2, percentage: 59.5 },
      { name: names[1], amount: 1600.22, percentage: 30.71 },
    ],
    otherAmount: 510,
  };
}

interface FakeGateway extends CostGateway {
  fetchSummary: Mock<CostGateway["fetchSummary"]>;
  fetchTrend: Mock<CostGateway["fetchTrend"]>;
  fetchBreakdown: Mock<CostGateway["fetchBreakdown"]>;
}

function makeGateway(overrides: Partial<CostSummaryResponse> = {}): FakeGateway {
  return {
    fetchSummary: vi.fn(() => Promise.resolve({ ...SUMMARY, ...overrides })),
    fetchTrend: vi.fn(() => Promise.resolve(TREND)),
    fetchBreakdown: vi.fn((_filter: CostFilter, grouping: CostGrouping) =>
      Promise.resolve(breakdownFor(grouping)),
    ),
  };
}

function renderDashboard(gateway: CostGateway) {
  const client = new QueryClient({
    defaultOptions: { queries: { retry: false, gcTime: 0 } },
  });
  return render(
    <QueryClientProvider client={client}>
      <CostDataContext.Provider value={gateway}>
        <CostDashboard subscriptionName="Contoso Workshop" initialFilter={FILTER} />
      </CostDataContext.Provider>
    </QueryClientProvider>,
  );
}

async function waitForLoaded() {
  await waitFor(() => {
    expect(screen.getByTestId("kpi-actual")).toHaveTextContent("5,210.42");
  });
}

beforeEach(() => {
  vi.restoreAllMocks();
});

afterEach(() => {
  cleanup();
});

describe("CostDashboard", () => {
  it("refetches every cost query when the metric changes", async () => {
    const user = userEvent.setup();
    const gateway = makeGateway();
    renderDashboard(gateway);
    await waitForLoaded();

    gateway.fetchSummary.mockClear();
    gateway.fetchTrend.mockClear();
    gateway.fetchBreakdown.mockClear();

    await user.selectOptions(screen.getByLabelText("Metric"), "AmortizedCost");

    await waitFor(() => {
      expect(gateway.fetchSummary).toHaveBeenCalledWith(
        expect.objectContaining({ metric: "AmortizedCost" }),
        expect.anything(),
      );
    });
    expect(gateway.fetchTrend).toHaveBeenCalledWith(
      expect.objectContaining({ metric: "AmortizedCost" }),
      expect.anything(),
    );
    const dimensions = gateway.fetchBreakdown.mock.calls.map((call) => call[1]);
    expect(new Set(dimensions)).toEqual(
      new Set(["ServiceName", "ResourceGroupName", "ResourceId"]),
    );
    for (const call of gateway.fetchBreakdown.mock.calls) {
      expect(call[0]).toMatchObject({ metric: "AmortizedCost" });
    }
  });

  it("focuses a dimension when a breakdown item is clicked", async () => {
    const user = userEvent.setup();
    const gateway = makeGateway();
    renderDashboard(gateway);
    await waitForLoaded();

    const panel = screen.getByRole("region", { name: "Resource group name" });
    await user.click(await within(panel).findByRole("button", { name: /rg-workshop-prod/ }));

    await waitFor(() => {
      expect(screen.getByLabelText("Group by")).toHaveValue("ResourceGroupName");
    });
    await waitFor(() => {
      expect(gateway.fetchSummary).toHaveBeenCalledWith(
        expect.objectContaining({ grouping: "ResourceGroupName" }),
        expect.anything(),
      );
    });
  });

  it("reserves chart and KPI space while data is loading", async () => {
    const pending: CostGateway = {
      fetchSummary: () => new Promise(() => {}),
      fetchTrend: () => new Promise(() => {}),
      fetchBreakdown: () => new Promise(() => {}),
    };
    renderDashboard(pending);

    expect(screen.getByTestId("trend-slot")).toHaveStyle({ height: `${TREND_CHART_HEIGHT}px` });
    for (const block of screen.getAllByTestId("kpi-block")) {
      expect(block).toHaveStyle({ minHeight: `${KPI_BLOCK_HEIGHT}px` });
    }
    cleanup();

    renderDashboard(makeGateway());
    await waitForLoaded();
    expect(screen.getByTestId("trend-slot")).toHaveStyle({ height: `${TREND_CHART_HEIGHT}px` });
    for (const block of screen.getAllByTestId("kpi-block")) {
      expect(block).toHaveStyle({ minHeight: `${KPI_BLOCK_HEIGHT}px` });
    }
  });

  it("explains the missing role instead of drawing an empty chart on 403", async () => {
    const forbidden = () => Promise.reject(new ApiForbiddenError("correlation-1"));
    renderDashboard({
      fetchSummary: forbidden,
      fetchTrend: forbidden,
      fetchBreakdown: forbidden,
    });

    expect(
      await screen.findByText(
        "You do not have access to this subscription's cost data. Ask a subscription owner to " +
          "grant you the Cost Management Reader role on the subscription, then refresh.",
      ),
    ).toBeInTheDocument();
    expect(screen.queryByTestId("trend-slot")).not.toBeInTheDocument();
  });

  it("states that the forecast is unavailable when the API returns none", async () => {
    renderDashboard(makeGateway({ forecast: null }));
    await waitForLoaded();

    expect(screen.getByText("Forecast unavailable")).toBeInTheDocument();
  });

  it("downloads the current view as CSV", async () => {
    const user = userEvent.setup();
    const createObjectURL = vi.fn((blob: Blob) => `blob:${blob.type}`);
    const revokeObjectURL = vi.fn();
    vi.stubGlobal("URL", Object.assign(URL, { createObjectURL, revokeObjectURL }));
    let downloadName = "";
    vi.spyOn(HTMLAnchorElement.prototype, "click").mockImplementation(function (
      this: HTMLAnchorElement,
    ) {
      downloadName = this.download;
    });

    renderDashboard(makeGateway());
    await waitForLoaded();
    await user.click(screen.getByRole("button", { name: "Download CSV" }));

    expect(downloadName).toBe("cost-analysis-2026-08-01_2026-08-31-ActualCost.csv");
    const blob = createObjectURL.mock.calls[0][0];
    await expect(blob.text()).resolves.toContain(
      "date,daily_cost,accumulated_cost,currency\r\n2026-08-01,180.25,180.25,USD",
    );
  });

  it("keeps keyboard focus visible on the command bar controls", async () => {
    const user = userEvent.setup();
    renderDashboard(makeGateway());
    await waitForLoaded();

    const refresh = screen.getByRole("button", { name: "Refresh" });
    refresh.focus();
    expect(refresh).toHaveFocus();
    await user.tab();
    expect(screen.getByRole("button", { name: "Download CSV" })).toHaveFocus();

    expect(tokensCss).toMatch(/:focus-visible\s*\{[^}]*outline:/);
  });
});

describe("buildTrendOption", () => {
  const input = {
    rangeStart: "2026-08-01",
    rangeEnd: "2026-08-05",
    points: TREND.points,
    budget: 400,
    forecastTotal: 900,
    currency: "USD",
    animate: false,
  };

  it("encodes actual, over-budget, forecast, overage, and budget-line series", () => {
    const option = buildTrendOption(input);
    expect(option.series.map((series) => series.id)).toEqual([
      TREND_SERIES_IDS.actual,
      TREND_SERIES_IDS.overBudget,
      TREND_SERIES_IDS.forecast,
      TREND_SERIES_IDS.forecastOverage,
      TREND_SERIES_IDS.budget,
    ]);
  });

  it("splits the accumulated cost at the budget line", () => {
    const option = buildTrendOption(input);
    const actual = option.series[0].data as (number | null)[];
    const over = option.series[1].data as (number | null)[];
    // Day three accumulates 651.50, so 400 sits under the line and 251.50 above it.
    expect(actual[2]).toBeCloseTo(400, 2);
    expect(over[2]).toBeCloseTo(251.5, 2);
    expect(option.series[4].data).toEqual([400, 400, 400, 400, 400]);
  });

  it("omits both forecast series when the API returns no forecast", () => {
    const option = buildTrendOption({ ...input, forecastTotal: null });
    expect(option.series.map((series) => series.id)).toEqual([
      TREND_SERIES_IDS.actual,
      TREND_SERIES_IDS.overBudget,
      TREND_SERIES_IDS.budget,
    ]);
  });
});

describe("toCsv", () => {
  it("writes the accumulated table for the current view", () => {
    expect(toCsv(TREND.points, "USD")).toBe(
      "date,daily_cost,accumulated_cost,currency\r\n" +
        "2026-08-01,180.25,180.25,USD\r\n" +
        "2026-08-02,210.50,390.75,USD\r\n" +
        "2026-08-03,260.75,651.50,USD\r\n",
    );
  });

  it("names the file after the period and metric", () => {
    expect(buildCsvFileName(FILTER)).toBe("cost-analysis-2026-08-01_2026-08-31-ActualCost.csv");
  });
});
