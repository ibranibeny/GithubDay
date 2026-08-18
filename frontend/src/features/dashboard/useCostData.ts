import { useQueries, useQuery, useQueryClient, type UseQueryResult } from "@tanstack/react-query";
import { createContext, useContext } from "react";

import { ApiForbiddenError, ApiHttpError, apiFetch } from "../../api/client";
import type { CostFilter, CostGrouping } from "../../api/contracts";
import { getAccessToken } from "../../auth/msal";

/** Cost data is rerated hourly at best, so a five minute window is generous, not stale. */
const STALE_TIME_MS = 5 * 60 * 1000;

/**
 * No budget API exists yet, so the threshold the chart and the budget KPI draw against is a
 * local constant. The UI says so rather than implying Azure returned it.
 */
export const MONTHLY_BUDGET_USD = 4000;

export const BREAKDOWN_DIMENSIONS: readonly CostGrouping[] = [
  "ServiceName",
  "ResourceGroupName",
  "ResourceId",
];

export const DIMENSION_LABELS: Record<CostGrouping, string> = {
  ServiceName: "Service name",
  ResourceGroupName: "Resource group name",
  ResourceId: "Resource",
  Tag: "Tag value",
};

export const METRIC_LABELS = {
  ActualCost: "Actual cost",
  AmortizedCost: "Amortized cost",
} as const;

/** Transient emphasis driven by the assistant; a target that is absent is simply not drawn. */
export interface CostHighlight {
  grouping: CostGrouping;
  value: string;
}

export interface CostChange {
  amount: number;
  percentage: number | null;
}

export interface TopDriver {
  name: string;
  amount: number;
}

interface CostContextFields {
  generatedAt: string;
  dataFreshness: string | null;
  currency: string | null;
  reratingNotice: string | null;
}

export interface CostSummaryResponse extends CostContextFields {
  total: number;
  previousTotal: number | null;
  change: CostChange | null;
  forecast: number | null;
  // TODO(Task 8): surface the top driver in the UI; the API already returns it.
  topDriver: TopDriver | null;
}

export interface TrendPoint {
  usageDate: string;
  amount: number;
}

export interface CostTrendResponse extends CostContextFields {
  points: TrendPoint[];
}

export interface BreakdownItem {
  name: string;
  amount: number;
  percentage: number;
}

export interface CostBreakdownResponse extends CostContextFields {
  grouping: CostGrouping;
  total: number;
  items: BreakdownItem[];
  otherAmount: number;
}

/**
 * The seam between the dashboard and the network. Production injects the authenticated client;
 * tests and the dev preview inject fixtures, so no component ever knows about tokens.
 */
export interface CostGateway {
  fetchSummary(filter: CostFilter, signal?: AbortSignal): Promise<CostSummaryResponse>;
  fetchTrend(filter: CostFilter, signal?: AbortSignal): Promise<CostTrendResponse>;
  fetchBreakdown(
    filter: CostFilter,
    grouping: CostGrouping,
    signal?: AbortSignal,
  ): Promise<CostBreakdownResponse>;
}

function toQuery(filter: CostFilter, grouping: CostGrouping): string {
  const params = new URLSearchParams({
    start: filter.from,
    end: filter.to,
    metric: filter.metric,
    grouping,
  });
  if (grouping === "Tag" && filter.tagKey) {
    params.set("tagKey", filter.tagKey);
  }
  return params.toString();
}

export const liveCostGateway: CostGateway = {
  fetchSummary: (filter, signal) =>
    apiFetch<CostSummaryResponse>(
      `/api/costs/summary?${toQuery(filter, filter.grouping)}`,
      getAccessToken,
      { signal },
    ),
  fetchTrend: (filter, signal) =>
    apiFetch<CostTrendResponse>(
      `/api/costs/trend?${toQuery(filter, filter.grouping)}`,
      getAccessToken,
      { signal },
    ),
  fetchBreakdown: (filter, grouping, signal) =>
    apiFetch<CostBreakdownResponse>(
      `/api/costs/breakdown?${toQuery(filter, grouping)}`,
      getAccessToken,
      {
        signal,
      },
    ),
};

export const CostDataContext = createContext<CostGateway>(liveCostGateway);

export interface NormalizedCostFilter {
  from: string;
  to: string;
  metric: string;
  grouping: string;
  tagKey: string | null;
}

/** Query keys must not change when an irrelevant field does, or every keystroke refetches. */
export function normalizeFilter(filter: CostFilter): NormalizedCostFilter {
  return {
    from: filter.from,
    to: filter.to,
    metric: filter.metric,
    grouping: filter.grouping,
    tagKey: filter.grouping === "Tag" ? (filter.tagKey ?? "").trim() : null,
  };
}

export const costQueryKeys = {
  all: ["costs"] as const,
  summary: (filter: CostFilter) => ["costs", "summary", normalizeFilter(filter)] as const,
  trend: (filter: CostFilter) => ["costs", "trend", normalizeFilter(filter)] as const,
  breakdown: (filter: CostFilter, grouping: CostGrouping) =>
    ["costs", "breakdown", { ...normalizeFilter(filter), grouping }] as const,
};

/** A 4xx will not heal on retry, and a 403 must reach the UI immediately to be explained. */
function shouldRetry(failureCount: number, error: Error): boolean {
  if (error instanceof ApiHttpError && error.status < 500) {
    return false;
  }
  return failureCount < 2;
}

export interface BreakdownQuery {
  dimension: CostGrouping;
  query: UseQueryResult<CostBreakdownResponse, Error>;
}

export interface CostData {
  summary: UseQueryResult<CostSummaryResponse, Error>;
  trend: UseQueryResult<CostTrendResponse, Error>;
  breakdowns: BreakdownQuery[];
  currency: string;
  forbidden: boolean;
  isFetching: boolean;
  refresh: () => void;
}

export function useCostData(filter: CostFilter): CostData {
  const gateway = useContext(CostDataContext);
  const queryClient = useQueryClient();

  const summary = useQuery({
    queryKey: costQueryKeys.summary(filter),
    queryFn: ({ signal }) => gateway.fetchSummary(filter, signal),
    staleTime: STALE_TIME_MS,
    refetchOnWindowFocus: false,
    retry: shouldRetry,
  });

  const trend = useQuery({
    queryKey: costQueryKeys.trend(filter),
    queryFn: ({ signal }) => gateway.fetchTrend(filter, signal),
    staleTime: STALE_TIME_MS,
    refetchOnWindowFocus: false,
    retry: shouldRetry,
  });

  const breakdownResults = useQueries({
    queries: BREAKDOWN_DIMENSIONS.map((dimension) => ({
      queryKey: costQueryKeys.breakdown(filter, dimension),
      queryFn: ({ signal }: { signal: AbortSignal }) =>
        gateway.fetchBreakdown(filter, dimension, signal),
      staleTime: STALE_TIME_MS,
      refetchOnWindowFocus: false,
      retry: shouldRetry,
    })),
  });

  const breakdowns = BREAKDOWN_DIMENSIONS.map((dimension, index) => ({
    dimension,
    query: breakdownResults[index],
  }));

  const everyQuery = [summary, trend, ...breakdownResults];

  return {
    summary,
    trend,
    breakdowns,
    currency: summary.data?.currency ?? trend.data?.currency ?? "USD",
    forbidden: everyQuery.some((query) => query.error instanceof ApiForbiddenError),
    isFetching: everyQuery.some((query) => query.isFetching),
    refresh: () => {
      void queryClient.invalidateQueries({ queryKey: costQueryKeys.all });
    },
  };
}

function isoDay(value: Date): string {
  return value.toISOString().slice(0, 10);
}

/** The whole calendar month, so the chart can draw a forecast into the days still to come. */
export function monthFilter(
  month: string,
  metric: CostFilter["metric"],
  grouping: CostGrouping,
  tagKey?: string,
): CostFilter {
  const [year, monthIndex] = month.split("-").map(Number);
  const start = new Date(Date.UTC(year, monthIndex - 1, 1));
  const end = new Date(Date.UTC(year, monthIndex, 0));
  return { from: isoDay(start), to: isoDay(end), metric, grouping, tagKey };
}

export function defaultCostFilter(today: Date = new Date()): CostFilter {
  const month = `${today.getUTCFullYear()}-${String(today.getUTCMonth() + 1).padStart(2, "0")}`;
  return monthFilter(month, "ActualCost", "ServiceName");
}

/**
 * Only dates, fixed-point amounts and a currency code reach the file, so no cell can begin with
 * a spreadsheet formula character. Adding free-text resource names here would need escaping.
 */
export function toCsv(points: TrendPoint[], currency: string): string {
  let accumulated = 0;
  const rows = points.map((point) => {
    accumulated += point.amount;
    return `${point.usageDate},${point.amount.toFixed(2)},${accumulated.toFixed(2)},${currency}`;
  });
  return ["date,daily_cost,accumulated_cost,currency", ...rows, ""].join("\r\n");
}

export function buildCsvFileName(filter: CostFilter): string {
  return `cost-analysis-${filter.from}_${filter.to}-${filter.metric}.csv`;
}

export function downloadCsv(fileName: string, content: string): void {
  const url = URL.createObjectURL(new Blob([content], { type: "text/csv;charset=utf-8" }));
  const link = document.createElement("a");
  link.href = url;
  link.download = fileName;
  document.body.append(link);
  link.click();
  link.remove();
  // WebKit latches the blob during the click task, so revoking has to wait a turn.
  setTimeout(() => URL.revokeObjectURL(url), 0);
}
