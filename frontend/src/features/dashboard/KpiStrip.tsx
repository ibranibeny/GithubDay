import type { CSSProperties } from "react";

import type { CostMetric } from "../../api/contracts";
import { formatCurrency, formatPercent } from "./format";
import { KPI_BLOCK_HEIGHT } from "./layout";
import { METRIC_LABELS, type CostSummaryResponse } from "./useCostData";

export interface KpiStripProps {
  summary: CostSummaryResponse | undefined;
  isPending: boolean;
  hasError: boolean;
  metric: CostMetric;
  budget: number;
  currency: string;
}

const BLOCK_STYLE = { minHeight: `${KPI_BLOCK_HEIGHT}px` };

export function KpiStrip({
  summary,
  isPending,
  hasError,
  metric,
  budget,
  currency,
}: KpiStripProps) {
  const loading = isPending && !summary;
  // A settled query with no data has nothing true to say, so the blocks say that rather than
  // formatting an absent total as $0.00 and a budget as untouched.
  const failed = !loading && (hasError || !summary);
  const consumed = summary ? summary.total / budget : 0;
  const overBudget = summary ? summary.total > budget : false;
  // Over budget the rail has to grow past the threshold, so the track spans the larger of the
  // two and the dotted marker slides back to wherever the budget now sits.
  const span = Math.max(consumed, 1);
  const fillWidth = (Math.min(consumed, 1) / span) * 100;
  const overWidth = (Math.max(consumed - 1, 0) / span) * 100;
  const meridianStyle = { "--meridian-at": `${(1 / span) * 100}%` } as CSSProperties;

  return (
    <section className="kpis" aria-label="Cost totals">
      <article className="kpi" data-testid="kpi-block" style={BLOCK_STYLE}>
        <h2 className="eyebrow">{METRIC_LABELS[metric]}</h2>
        {loading ? (
          <Skeleton wide />
        ) : failed || !summary ? (
          <Unavailable />
        ) : (
          <>
            <p className="kpi__value num" data-testid="kpi-actual">
              {formatCurrency(summary.total, currency)}
            </p>
            <p className="kpi__note">{describeChange(summary, currency)}</p>
          </>
        )}
      </article>

      <article className="kpi" data-testid="kpi-block" style={BLOCK_STYLE}>
        <h2 className="eyebrow">Forecast</h2>
        {loading ? (
          <Skeleton wide />
        ) : failed || !summary ? (
          <Unavailable />
        ) : summary.forecast == null ? (
          <>
            <p className="kpi__value kpi__value--absent">Forecast unavailable</p>
            <p className="kpi__note">
              Azure forecasts this scope once the period has more history.
            </p>
          </>
        ) : (
          <>
            <p className="kpi__value num">{formatCurrency(summary.forecast, currency)}</p>
            <p className="kpi__note">Projected total for the selected period.</p>
          </>
        )}
      </article>

      <article
        className={`kpi kpi--budget${overBudget ? " kpi--over" : ""}`}
        data-testid="kpi-block"
        style={BLOCK_STYLE}
      >
        <h2 className="eyebrow">Monthly budget</h2>
        {loading ? (
          <Skeleton wide />
        ) : failed || !summary ? (
          <Unavailable />
        ) : (
          <>
            <p className="kpi__value num">{formatCurrency(budget, currency)}</p>
            {/* The meridian: the same threshold the trend chart draws, at wallet scale. */}
            <div className="meridian" style={meridianStyle} aria-hidden>
              <span className="meridian__fill" style={{ width: `${fillWidth}%` }} />
              {overBudget ? (
                <span className="meridian__over" style={{ width: `${overWidth}%` }} />
              ) : null}
            </div>
            <p className="kpi__note">
              {overBudget
                ? `Over by ${formatCurrency(summary.total - budget, currency)}.`
                : `${formatPercent(consumed * 100)} used · ${formatCurrency(
                    budget - summary.total,
                    currency,
                  )} left.`}{" "}
              Set locally; no budget API is connected.
            </p>
          </>
        )}
      </article>
    </section>
  );
}

function Unavailable() {
  return (
    <p className="kpi__note" role="alert">
      Cost totals are unavailable. Refresh to try again.
    </p>
  );
}

function describeChange(summary: CostSummaryResponse, currency: string): string {
  if (!summary.change || summary.previousTotal == null) {
    return "No comparable previous period.";
  }
  const direction = summary.change.amount >= 0 ? "up" : "down";
  const magnitude = formatCurrency(Math.abs(summary.change.amount), currency);
  const percentage =
    summary.change.percentage == null
      ? ""
      : ` (${formatPercent(Math.abs(summary.change.percentage))})`;
  return `${magnitude}${percentage} ${direction} on the previous period.`;
}

function Skeleton({ wide }: { wide?: boolean }) {
  return (
    <span className={`skeleton${wide ? " skeleton--wide" : ""}`} role="status">
      <span className="visually-hidden">Loading</span>
    </span>
  );
}
