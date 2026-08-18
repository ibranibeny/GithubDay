import ReactECharts from "echarts-for-react";

import type { CostGrouping } from "../../api/contracts";
import { usePrefersReducedMotion } from "../../app/usePrefersReducedMotion";
import { CHART_PALETTE, buildDonutOption } from "./chartOptions";
import { formatCurrency, formatPercent } from "./format";
import { DONUT_CHART_HEIGHT } from "./layout";
import { DIMENSION_LABELS, type BreakdownQuery } from "./useCostData";

const SLOT_STYLE = { height: `${DONUT_CHART_HEIGHT}px` };
const FILL_STYLE = { height: "100%", width: "100%" };
const LEGEND_LIMIT = 5;

export interface CostBreakdownGridProps {
  breakdowns: BreakdownQuery[];
  currency: string;
  activeDimension: CostGrouping;
  onFocusDimension: (dimension: CostGrouping) => void;
}

export function CostBreakdownGrid({
  breakdowns,
  currency,
  activeDimension,
  onFocusDimension,
}: CostBreakdownGridProps) {
  return (
    <div className="breakdowns">
      {breakdowns.map((breakdown) => (
        <CostBreakdownPanel
          key={breakdown.dimension}
          breakdown={breakdown}
          currency={currency}
          isActive={breakdown.dimension === activeDimension}
          onFocusDimension={onFocusDimension}
        />
      ))}
    </div>
  );
}

export interface CostBreakdownPanelProps {
  breakdown: BreakdownQuery;
  currency: string;
  isActive: boolean;
  onFocusDimension: (dimension: CostGrouping) => void;
}

export function CostBreakdownPanel({
  breakdown,
  currency,
  isActive,
  onFocusDimension,
}: CostBreakdownPanelProps) {
  const reducedMotion = usePrefersReducedMotion();
  const { dimension, query } = breakdown;
  const label = DIMENSION_LABELS[dimension];
  const items = query.data?.items.slice(0, LEGEND_LIMIT) ?? [];

  return (
    <section
      className={`panel${isActive ? " panel--active" : ""}`}
      aria-label={label}
      data-dimension={dimension}
    >
      <header className="panel__head">
        <h2 className="section-title">{label}</h2>
        {isActive ? <span className="panel__badge">Grouping</span> : null}
      </header>
      <div className="panel__slot" data-testid="breakdown-slot" style={SLOT_STYLE}>
        {query.isPending ? (
          <span className="skeleton skeleton--block" role="status">
            <span className="visually-hidden">Loading {label}</span>
          </span>
        ) : query.isError || !query.data ? (
          <p className="slot-message" role="alert">
            {label} did not load.
          </p>
        ) : (
          <>
            <ReactECharts
              option={buildDonutOption({
                items: query.data.items,
                otherAmount: query.data.otherAmount,
                currency,
                animate: !reducedMotion,
              })}
              style={FILL_STYLE}
              opts={{ renderer: "svg" }}
              notMerge
              lazyUpdate
            />
            <p className="panel__total num" aria-hidden>
              {formatCurrency(query.data.total, currency)}
            </p>
          </>
        )}
      </div>
      <ol className="ranked">
        {items.map((item, index) => (
          <li key={item.name}>
            <button
              type="button"
              className="ranked__row"
              onClick={() => onFocusDimension(dimension)}
              title={`Group the period by ${label.toLowerCase()}`}
            >
              <span
                className="ranked__swatch"
                style={{ backgroundColor: CHART_PALETTE[index % CHART_PALETTE.length] }}
                aria-hidden
              />
              <span className="ranked__name">{item.name}</span>
              <span className="ranked__amount num">{formatCurrency(item.amount, currency)}</span>
              <span className="ranked__share num">{formatPercent(item.percentage)}</span>
            </button>
          </li>
        ))}
        {query.data && query.data.otherAmount > 0 ? (
          <li className="ranked__rest">
            <span className="ranked__swatch ranked__swatch--rest" aria-hidden />
            <span className="ranked__name">Other</span>
            <span className="ranked__amount num">
              {formatCurrency(query.data.otherAmount, currency)}
            </span>
          </li>
        ) : null}
      </ol>
    </section>
  );
}
