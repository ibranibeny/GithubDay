import { formatCompactCurrency, formatCurrency, formatDayLabel } from "./format";
import type { BreakdownItem, TrendPoint } from "./useCostData";

/**
 * Eight hues, not eight tints of one: a reader has to tell App Service from Cosmos DB at a
 * glance, and a single-hue ramp only encodes magnitude. Azure blue leads because the accumulated
 * actual is the series everything else is judged against.
 */
export const CHART_PALETTE = [
  "#0f6cbd", // azure
  "#0e7c86", // teal
  "#107c41", // green
  "#c07800", // amber
  "#b3261e", // red
  "#6b4fbb", // purple
  "#3b3f46", // ink
  "#8a9099", // neutral
] as const;

const AZURE = CHART_PALETTE[0];
const RED = CHART_PALETTE[4];
const INK = CHART_PALETTE[6];
const GRID_LINE = "#e6e8eb";

/**
 * Axis labels are 11px text, so they carry the 4.5:1 floor: `--ink-3` clears it at 4.83:1 where
 * the lighter neutral the grid lines use would not.
 */
export const AXIS_LABEL_COLOR = "#6b7280";

/** The `--line` token the legend's rest swatch paints, so the slice and the swatch agree. */
export const REST_SLICE_COLOR = "#d8dbe0";

export const TREND_SERIES_IDS = {
  actual: "actual-cost",
  overBudget: "over-budget",
  forecast: "forecast",
  forecastOverage: "forecast-overage",
  budget: "budget-line",
} as const;

export interface ChartSeries {
  id: string;
  name: string;
  type: string;
  data: (number | null)[] | { name: string; value: number }[];
  [key: string]: unknown;
}

export interface ChartOption {
  series: ChartSeries[];
  [key: string]: unknown;
}

export interface TrendChartInput {
  rangeStart: string;
  rangeEnd: string;
  points: TrendPoint[];
  budget: number;
  forecastTotal: number | null;
  currency: string;
  animate: boolean;
}

const MAX_AXIS_DAYS = 400;

function eachDay(rangeStart: string, rangeEnd: string): string[] {
  const days: string[] = [];
  const cursor = new Date(`${rangeStart}T00:00:00Z`);
  const end = new Date(`${rangeEnd}T00:00:00Z`);
  while (cursor <= end && days.length < MAX_AXIS_DAYS) {
    days.push(cursor.toISOString().slice(0, 10));
    cursor.setUTCDate(cursor.getUTCDate() + 1);
  }
  return days;
}

function areaSeries(
  id: string,
  name: string,
  data: (number | null)[],
  color: string,
  opacity: number,
  stack: string,
  dashed: boolean,
): ChartSeries {
  return {
    id,
    name,
    type: "line",
    stack,
    data,
    symbol: "none",
    smooth: false,
    connectNulls: false,
    lineStyle: { width: dashed ? 1.5 : 2, color, type: dashed ? "dashed" : "solid" },
    areaStyle: { color, opacity },
    emphasis: { focus: "series" },
  };
}

/**
 * The accumulated cost is split at the budget rather than drawn as one area: the point of the
 * chart is the day the line is crossed, and a single area hides it.
 */
export function buildTrendOption(input: TrendChartInput): ChartOption {
  const { rangeStart, rangeEnd, points, budget, forecastTotal, currency, animate } = input;
  const days = eachDay(rangeStart, rangeEnd);
  const dailyByDate = new Map(points.map((point) => [point.usageDate, point.amount]));

  const under: (number | null)[] = [];
  const over: (number | null)[] = [];
  let accumulated = 0;
  let lastActualIndex = -1;
  days.forEach((day, index) => {
    const amount = dailyByDate.get(day);
    if (amount === undefined) {
      under.push(null);
      over.push(null);
      return;
    }
    accumulated += amount;
    lastActualIndex = index;
    under.push(Math.min(accumulated, budget));
    over.push(Math.max(accumulated - budget, 0));
  });

  const series: ChartSeries[] = [
    areaSeries(TREND_SERIES_IDS.actual, "Actual cost", under, AZURE, 0.18, "actual", false),
    areaSeries(TREND_SERIES_IDS.overBudget, "Over budget", over, RED, 0.24, "actual", false),
  ];

  if (forecastTotal !== null && lastActualIndex >= 0 && lastActualIndex < days.length - 1) {
    const remaining = days.length - 1 - lastActualIndex;
    const step = (forecastTotal - accumulated) / remaining;
    const forecastUnder: (number | null)[] = [];
    const forecastOver: (number | null)[] = [];
    days.forEach((_day, index) => {
      if (index < lastActualIndex) {
        forecastUnder.push(null);
        forecastOver.push(null);
        return;
      }
      // The join day repeats the actual total so the forecast grows out of the area, not beside it.
      const projected = accumulated + step * (index - lastActualIndex);
      forecastUnder.push(Math.min(projected, budget));
      forecastOver.push(Math.max(projected - budget, 0));
    });
    series.push(
      areaSeries(
        TREND_SERIES_IDS.forecast,
        "Forecast",
        forecastUnder,
        AZURE,
        0.07,
        "forecast",
        true,
      ),
      areaSeries(
        TREND_SERIES_IDS.forecastOverage,
        "Forecast overage",
        forecastOver,
        RED,
        0.1,
        "forecast",
        true,
      ),
    );
  }

  series.push({
    id: TREND_SERIES_IDS.budget,
    name: "Monthly budget",
    type: "line",
    data: days.map(() => budget),
    symbol: "none",
    silent: true,
    z: 5,
    lineStyle: { width: 1.5, color: INK, type: "dotted" },
  });

  return {
    animation: animate,
    grid: { left: 64, right: 16, top: 12, bottom: 26, containLabel: false },
    tooltip: {
      trigger: "axis",
      confine: true,
      axisPointer: { type: "line", lineStyle: { color: INK, width: 1, type: "solid" } },
      valueFormatter: (value: unknown) =>
        typeof value === "number" ? formatCurrency(value, currency) : "-",
    },
    xAxis: {
      type: "category",
      data: days,
      boundaryGap: false,
      axisLine: { lineStyle: { color: GRID_LINE } },
      axisTick: { show: false },
      axisLabel: {
        color: AXIS_LABEL_COLOR,
        fontSize: 11,
        formatter: (value: string) => formatDayLabel(value),
        hideOverlap: true,
      },
    },
    yAxis: {
      type: "value",
      splitLine: { lineStyle: { color: GRID_LINE, type: "dashed" } },
      axisLabel: {
        color: AXIS_LABEL_COLOR,
        fontSize: 11,
        formatter: (value: number) => formatCompactCurrency(value, currency),
      },
    },
    series,
  };
}

export interface DonutChartInput {
  items: BreakdownItem[];
  otherAmount: number;
  currency: string;
  animate: boolean;
}

interface DonutDatum {
  name: string;
  value: number;
  itemStyle?: { color: string };
}

export function buildDonutOption(input: DonutChartInput): ChartOption {
  const data: DonutDatum[] = input.items.map((item) => ({ name: item.name, value: item.amount }));
  if (input.otherAmount > 0) {
    data.push({
      name: "Other",
      value: input.otherAmount,
      itemStyle: { color: REST_SLICE_COLOR },
    });
  }
  return {
    animation: input.animate,
    color: [...CHART_PALETTE],
    tooltip: {
      trigger: "item",
      confine: true,
      valueFormatter: (value: unknown) =>
        typeof value === "number" ? formatCurrency(value, input.currency) : "-",
    },
    series: [
      {
        id: "breakdown",
        name: "Cost",
        type: "pie",
        radius: ["64%", "92%"],
        center: ["50%", "50%"],
        avoidLabelOverlap: false,
        label: { show: false },
        labelLine: { show: false },
        itemStyle: { borderColor: "#ffffff", borderWidth: 1.5 },
        data,
      },
    ],
  };
}
