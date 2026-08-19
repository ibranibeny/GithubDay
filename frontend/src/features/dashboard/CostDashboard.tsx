import { ShieldAlert } from "lucide-react";
import { useState } from "react";

import {
  isChartAction,
  isEvidence,
  type ChartAction,
  type CostFilter,
  type CostGrouping,
  type Evidence,
} from "../../api/contracts";
import { AppShell } from "../../app/AppShell";
import { ChatPanel } from "../chat/ChatPanel";
import { CostBreakdownGrid } from "./CostBreakdown";
import { CostCommandBar } from "./CostCommandBar";
import { CostFilters } from "./CostFilters";
import { CostTrendChart } from "./CostTrendChart";
import { KpiStrip } from "./KpiStrip";
import {
  MONTHLY_BUDGET_USD,
  buildCsvFileName,
  defaultCostFilter,
  downloadCsv,
  monthFilter,
  toCsv,
  useCostData,
  type CostHighlight,
} from "./useCostData";

export interface CostDashboardProps {
  subscriptionName: string;
  initialFilter?: CostFilter;
}

/**
 * The period control addresses whole calendar months, so a suggested window is widened to the
 * month it starts in; an incomplete or inverted window is not a period and is left alone.
 */
function withWindow(filter: CostFilter, start?: string, end?: string): CostFilter {
  if (!start || !end || end < start) {
    return filter;
  }
  const month = monthFilter(start.slice(0, 7), filter.metric, filter.grouping, filter.tagKey);
  return { ...filter, from: month.from, to: month.to };
}

export function CostDashboard({ subscriptionName, initialFilter }: CostDashboardProps) {
  const [filter, setFilter] = useState<CostFilter>(() => initialFilter ?? defaultCostFilter());
  // Transient, not part of the query key: emphasis is a reading aid, not a different question.
  const [highlight, setHighlight] = useState<CostHighlight | null>(null);
  const { summary, trend, breakdowns, currency, forbidden, isFetching, refresh } =
    useCostData(filter);

  const points = trend.data?.points ?? [];
  const focusDimension = (dimension: CostGrouping) => {
    setFilter((current) => ({ ...current, grouping: dimension, tagKey: undefined }));
    setHighlight(null);
  };

  /** Applying a citation moves the page to the exact window the figure was read from. */
  const applyEvidence = (evidence: Evidence) => {
    if (!isEvidence(evidence)) {
      return;
    }
    setFilter((current) =>
      withWindow({ ...current, metric: evidence.metric }, evidence.periodStart, evidence.periodEnd),
    );
    setHighlight({ grouping: filter.grouping, value: evidence.dimension });
  };

  /** Model output only ever reaches the dashboard through this gate. */
  const applyChartAction = (action: ChartAction) => {
    if (!isChartAction(action)) {
      return;
    }

    if (action.kind === "highlight-series") {
      if (action.grouping && action.value) {
        setHighlight({ grouping: action.grouping, value: action.value });
      }
      return;
    }

    // A tag grouping without a key is a query the API always rejects, so it is not applied at
    // all: half of it would silently change the grouping and break every panel.
    if (action.grouping === "Tag" && !action.value) {
      return;
    }

    setFilter((current) => {
      const next: CostFilter = { ...current };
      if (action.metric) {
        next.metric = action.metric;
      }
      if (action.grouping) {
        next.grouping = action.grouping;
        // The value is only ever read as a tag key, never as a service or resource name.
        next.tagKey = action.grouping === "Tag" ? action.value : undefined;
      }
      return withWindow(next, action.start, action.end);
    });
  };

  return (
    <AppShell
      chat={
        <ChatPanel
          filter={filter}
          currency={currency}
          onApplyEvidence={applyEvidence}
          onApplyAction={applyChartAction}
        />
      }
    >
      <div className="page">
        <header className="page__head">
          <p className="page__scope">{subscriptionName}</p>
          <h1 className="page__title">Cost analysis</h1>
          <CostCommandBar
            onRefresh={refresh}
            onDownload={() => downloadCsv(buildCsvFileName(filter), toCsv(points, currency))}
            isFetching={isFetching}
            canDownload={points.length > 0}
            dataFreshness={summary.data?.dataFreshness ?? trend.data?.dataFreshness ?? null}
            reratingNotice={summary.data?.reratingNotice ?? null}
          />
        </header>

        <CostFilters
          filter={filter}
          subscriptionName={subscriptionName}
          onChange={(next) => {
            setFilter(next);
            setHighlight(null);
          }}
        />

        {forbidden ? (
          <AccessRequired />
        ) : (
          <>
            <KpiStrip
              summary={summary.data}
              isPending={summary.isPending}
              hasError={summary.isError}
              metric={filter.metric}
              budget={MONTHLY_BUDGET_USD}
              currency={currency}
            />
            <CostTrendChart
              points={points}
              rangeStart={filter.from}
              rangeEnd={filter.to}
              budget={MONTHLY_BUDGET_USD}
              forecastTotal={summary.data?.forecast ?? null}
              currency={currency}
              isPending={trend.isPending}
              hasError={trend.isError}
            />
            <CostBreakdownGrid
              breakdowns={breakdowns}
              currency={currency}
              activeDimension={filter.grouping}
              highlight={highlight}
              onFocusDimension={focusDimension}
            />
          </>
        )}
      </div>
    </AppShell>
  );
}

/** A 403 is a role problem with a known fix, so the page states the fix instead of a blank chart. */
function AccessRequired() {
  return (
    <section className="access" role="alert">
      <ShieldAlert size={20} aria-hidden />
      <div>
        <h2 className="section-title">Cost data needs a role assignment</h2>
        <p className="access__body">
          You do not have access to this subscription&apos;s cost data. Ask a subscription owner to
          grant you the Cost Management Reader role on the subscription, then refresh.
        </p>
      </div>
    </section>
  );
}
