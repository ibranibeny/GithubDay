import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { cleanup, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import type { CSSProperties } from "react";
import { afterEach, beforeEach, describe, expect, it, vi, type Mock } from "vitest";

import { ApiForbiddenError, ApiHttpError } from "../../api/client";
import type { CostFilter, CostGrouping } from "../../api/contracts";
import tokensCss from "../../styles/tokens.css?raw";
import { ChatGatewayContext, type ChatGateway } from "../chat/useCostChat";
import { CostDashboard } from "./CostDashboard";
import {
  AXIS_LABEL_COLOR,
  REST_SLICE_COLOR,
  TREND_SERIES_IDS,
  buildDonutOption,
  buildTrendOption,
} from "./chartOptions";
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

const IDLE_CHAT: ChatGateway = { send: () => new Promise(() => {}) };

function chatReplying(chartActions: unknown[]): ChatGateway {
  return {
    send: () =>
      Promise.resolve({
        answer: "Here is what the data shows.",
        evidence: [],
        chartActions,
        explanationAvailable: true,
      } as Awaited<ReturnType<ChatGateway["send"]>>),
  };
}

/** Asks a question, then applies the single action the reply carried. */
async function applyFirstAction(user: ReturnType<typeof userEvent.setup>) {
  await user.type(screen.getByLabelText("Ask about these costs"), "What changed?");
  await user.click(screen.getByRole("button", { name: "Send" }));
  const actions = await screen.findByRole("group", { name: "Chart actions" });
  await user.click(within(actions).getAllByRole("button")[0]);
}

function renderDashboard(gateway: CostGateway, chat: ChatGateway = IDLE_CHAT) {
  const client = new QueryClient({
    defaultOptions: { queries: { retry: false, gcTime: 0 }, mutations: { retry: false } },
  });
  return render(
    <QueryClientProvider client={client}>
      <ChatGatewayContext.Provider value={chat}>
        <CostDataContext.Provider value={gateway}>
          <CostDashboard subscriptionName="Contoso Workshop" initialFilter={FILTER} />
        </CostDataContext.Provider>
      </ChatGatewayContext.Provider>
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

  it("says the totals are unavailable instead of printing zeros when the summary fails", async () => {
    const gateway = makeGateway();
    // A 4xx settles without retrying, so the strip is observed in its terminal error state.
    gateway.fetchSummary.mockRejectedValue(new ApiHttpError(400, "correlation-2"));
    renderDashboard(gateway);

    const alerts = await screen.findAllByText("Cost totals are unavailable. Refresh to try again.");
    expect(alerts).toHaveLength(3);
    for (const alert of alerts) {
      expect(alert).toHaveAttribute("role", "alert");
    }
    expect(screen.queryByText("$0.00")).not.toBeInTheDocument();
    expect(screen.queryByText(/left\./)).not.toBeInTheDocument();
    expect(screen.queryByText("No comparable previous period.")).not.toBeInTheDocument();
  });

  it("states that no usage was recorded when the trend returns no points", async () => {
    const gateway = makeGateway();
    gateway.fetchTrend.mockResolvedValue({ ...TREND, points: [] });
    renderDashboard(gateway);
    await waitForLoaded();

    expect(
      within(screen.getByTestId("trend-slot")).getByText("No usage was recorded in this period."),
    ).toBeInTheDocument();
  });

  it("states that no usage was recorded when a breakdown has no slices", async () => {
    const gateway = makeGateway();
    gateway.fetchBreakdown.mockImplementation((_filter: CostFilter, grouping: CostGrouping) =>
      Promise.resolve({ ...breakdownFor(grouping), total: 0, items: [], otherAmount: 0 }),
    );
    renderDashboard(gateway);
    await waitForLoaded();

    const panel = screen.getByRole("region", { name: "Service name" });
    expect(within(panel).getByText("No usage was recorded in this period.")).toBeInTheDocument();
  });

  it("keeps the period options fixed when an earlier month is selected", async () => {
    const user = userEvent.setup();
    renderDashboard(makeGateway());
    await waitForLoaded();

    const period = screen.getByLabelText("Period") as HTMLSelectElement;
    const before = Array.from(period.options, (option) => option.value);
    expect(before).toHaveLength(6);
    expect(before).toContain("2026-08");

    await user.selectOptions(period, before[0]);
    await waitFor(() => {
      expect(period).toHaveValue(before[0]);
    });

    expect(Array.from(period.options, (option) => option.value)).toEqual(before);
  });

  it("marks the refresh control busy while cost queries are in flight", () => {
    renderDashboard({
      fetchSummary: () => new Promise(() => {}),
      fetchTrend: () => new Promise(() => {}),
      fetchBreakdown: () => new Promise(() => {}),
    });

    expect(screen.getByRole("button", { name: "Refresh" })).toHaveAttribute("aria-busy", "true");
  });

  it("names ranked rows with the grouping action and leaves the active grouping inert", async () => {
    renderDashboard(makeGateway());
    await waitForLoaded();

    const active = screen.getByRole("region", { name: "Service name" });
    expect(within(active).queryAllByRole("button")).toHaveLength(0);

    const other = screen.getByRole("region", { name: "Resource group name" });
    expect(
      within(other).getByRole("button", {
        name: "Group costs by resource group name: rg-workshop-prod",
      }),
    ).toBeInTheDocument();
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

  it("moves the period, the metric, and the emphasis when chat evidence is applied", async () => {
    const user = userEvent.setup();
    const chat: ChatGateway = {
      send: vi.fn(() =>
        Promise.resolve({
          answer: "App Service led July.",
          evidence: [
            {
              metric: "AmortizedCost" as const,
              dimension: "Azure App Service",
              periodStart: "2026-07-01",
              periodEnd: "2026-07-31",
              amount: 1620.4,
            },
          ],
          chartActions: [],
          explanationAvailable: true,
        }),
      ),
    };
    renderDashboard(makeGateway(), chat);
    await waitForLoaded();

    await user.type(screen.getByLabelText("Ask about these costs"), "What led July?");
    await user.click(screen.getByRole("button", { name: "Send" }));
    await user.click(
      await screen.findByRole("button", {
        name: "Apply Amortized cost for Azure App Service, 2026-07-01 to 2026-07-31",
      }),
    );

    await waitFor(() => {
      expect(screen.getByLabelText("Period")).toHaveValue("2026-07");
    });
    expect(screen.getByLabelText("Metric")).toHaveValue("AmortizedCost");

    const services = screen.getByRole("region", { name: "Service name" });
    const emphasised = services.querySelectorAll('[data-emphasised="true"]');
    expect(emphasised).toHaveLength(1);
    expect(emphasised[0]).toHaveTextContent("Azure App Service");
  });

  it("announces the series the assistant emphasised", async () => {
    const user = userEvent.setup();
    renderDashboard(
      makeGateway(),
      chatReplying([
        { kind: "highlight-series", grouping: "ServiceName", value: "Azure App Service" },
      ]),
    );
    await waitForLoaded();
    await applyFirstAction(user);

    const services = screen.getByRole("region", { name: "Service name" });
    expect(within(services).getByRole("status")).toHaveTextContent("Azure App Service");
  });

  it("ignores a tag grouping the API would always reject", async () => {
    const user = userEvent.setup();
    const gateway = makeGateway();
    renderDashboard(gateway, chatReplying([{ kind: "set-filter", grouping: "Tag" }]));
    await waitForLoaded();
    await applyFirstAction(user);

    expect(screen.getByLabelText("Group by")).toHaveValue("ServiceName");
    for (const call of gateway.fetchSummary.mock.calls) {
      expect(call[0].grouping).not.toBe("Tag");
    }
  });

  it("ignores a suggested period whose end precedes its start", async () => {
    const user = userEvent.setup();
    renderDashboard(
      makeGateway(),
      chatReplying([{ kind: "set-filter", start: "2026-07-31", end: "2026-07-01" }]),
    );
    await waitForLoaded();
    await applyFirstAction(user);

    expect(screen.getByLabelText("Period")).toHaveValue("2026-08");
  });

  it("widens a suggested period to the month the period control can show", async () => {
    const user = userEvent.setup();
    const gateway = makeGateway();
    renderDashboard(
      gateway,
      chatReplying([{ kind: "set-filter", start: "2026-06-05", end: "2026-06-20" }]),
    );
    await waitForLoaded();
    await applyFirstAction(user);

    await waitFor(() => {
      expect(screen.getByLabelText("Period")).toHaveValue("2026-06");
    });
    await waitFor(() => {
      expect(gateway.fetchSummary).toHaveBeenCalledWith(
        expect.objectContaining({ from: "2026-06-01", to: "2026-06-30" }),
        expect.anything(),
      );
    });
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

  it("leaves the over-budget series at zero while the budget is never reached", () => {
    const option = buildTrendOption({ ...input, budget: 10_000, forecastTotal: null });
    const actual = option.series[0].data as (number | null)[];
    const over = option.series[1].data as (number | null)[];

    // The accumulated total stays below the line, so "actual" carries the whole running sum.
    expect(actual[0]).toBeCloseTo(180.25, 2);
    expect(actual[1]).toBeCloseTo(390.75, 2);
    expect(actual[2]).toBeCloseTo(651.5, 2);
    expect(over.filter((value) => value !== null)).toEqual([0, 0, 0]);
  });

  it("pins the actual series at the budget when it is exceeded on day one", () => {
    const option = buildTrendOption({ ...input, budget: 100, forecastTotal: null });
    const actual = option.series[0].data as (number | null)[];
    const over = option.series[1].data as (number | null)[];

    expect(actual.filter((value) => value !== null)).toEqual([100, 100, 100]);
    expect(over[0]).toBeCloseTo(80.25, 2);
    expect(over[1]).toBeCloseTo(290.75, 2);
    expect(over[2]).toBeCloseTo(551.5, 2);
  });

  it("draws axis labels at a colour that clears AA contrast on white", () => {
    const option = buildTrendOption(input);
    const xAxis = option.xAxis as { axisLabel: { color: string } };
    const yAxis = option.yAxis as { axisLabel: { color: string } };

    expect(AXIS_LABEL_COLOR).toBe("#6b7280");
    expect(xAxis.axisLabel.color).toBe(AXIS_LABEL_COLOR);
    expect(yAxis.axisLabel.color).toBe(AXIS_LABEL_COLOR);
  });
});

describe("buildDonutOption", () => {
  const items = [
    { name: "Azure App Service", amount: 3100.2, percentage: 59.5 },
    { name: "Azure Cosmos DB", amount: 1600.22, percentage: 30.71 },
  ];

  it("omits the Other slice when nothing is left over", () => {
    const option = buildDonutOption({ items, otherAmount: 0, currency: "USD", animate: false });
    const data = option.series[0].data as { name: string }[];

    expect(data).toHaveLength(2);
    expect(data.map((slice) => slice.name)).not.toContain("Other");
  });

  it("paints the Other slice with the neutral the legend rest swatch uses", () => {
    const option = buildDonutOption({ items, otherAmount: 510, currency: "USD", animate: false });
    const data = option.series[0].data as { name: string; itemStyle?: { color: string } }[];

    expect(data).toHaveLength(3);
    expect(data[2].name).toBe("Other");
    expect(data[2].itemStyle?.color).toBe(REST_SLICE_COLOR);
    // The legend swatch paints `--line`, so the slice and the swatch cannot drift apart.
    expect(tokensCss).toContain(`--line: ${REST_SLICE_COLOR}`);
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
