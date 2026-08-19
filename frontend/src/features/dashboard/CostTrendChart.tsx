import ReactECharts from "echarts-for-react";

import { usePrefersReducedMotion } from "../../app/usePrefersReducedMotion";
import { CHART_PALETTE, buildTrendOption } from "./chartOptions";
import { formatCurrency } from "./format";
import { TREND_CHART_HEIGHT } from "./layout";
import type { TrendPoint } from "./useCostData";

const SLOT_STYLE = { height: `${TREND_CHART_HEIGHT}px` };
const FILL_STYLE = { height: "100%", width: "100%" };

export interface CostTrendChartProps {
  points: TrendPoint[];
  rangeStart: string;
  rangeEnd: string;
  budget: number;
  forecastTotal: number | null;
  currency: string;
  isPending: boolean;
  hasError: boolean;
}

interface LegendEntry {
  label: string;
  color: string;
  style: "area" | "dashed" | "dotted";
}

export function CostTrendChart({
  points,
  rangeStart,
  rangeEnd,
  budget,
  forecastTotal,
  currency,
  isPending,
  hasError,
}: CostTrendChartProps) {
  const reducedMotion = usePrefersReducedMotion();
  const option = buildTrendOption({
    rangeStart,
    rangeEnd,
    points,
    budget,
    forecastTotal,
    currency,
    animate: !reducedMotion,
  });

  const legend: LegendEntry[] = [
    { label: "Actual cost", color: CHART_PALETTE[0], style: "area" },
    { label: "Over budget", color: CHART_PALETTE[4], style: "area" },
    ...(forecastTotal === null
      ? []
      : ([
          { label: "Forecast", color: CHART_PALETTE[0], style: "dashed" },
          { label: "Forecast overage", color: CHART_PALETTE[4], style: "dashed" },
        ] as LegendEntry[])),
    { label: "Monthly budget", color: CHART_PALETTE[6], style: "dotted" },
  ];

  return (
    <section className="trend" aria-label="Accumulated cost">
      <div className="trend__head">
        <h2 className="section-title">Accumulated cost</h2>
        <p className="trend__budget num">{formatCurrency(budget, currency)} budget</p>
        <ul className="legend">
          {legend.map((entry) => (
            <li key={entry.label}>
              <span
                className={`legend__mark legend__mark--${entry.style}`}
                style={{ borderColor: entry.color, backgroundColor: entry.color }}
                aria-hidden
              />
              {entry.label}
            </li>
          ))}
        </ul>
      </div>
      <div className="trend__slot" data-testid="trend-slot" style={SLOT_STYLE}>
        {isPending ? (
          <span className="skeleton skeleton--block" role="status">
            <span className="visually-hidden">Loading the accumulated cost chart</span>
          </span>
        ) : hasError ? (
          <p className="slot-message" role="alert">
            Cost data did not load. Select Refresh to try again.
          </p>
        ) : points.length === 0 ? (
          <p className="slot-message">No usage was recorded in this period.</p>
        ) : (
          <ReactECharts
            option={option}
            style={FILL_STYLE}
            opts={{ renderer: "svg" }}
            notMerge
            lazyUpdate
          />
        )}
      </div>
    </section>
  );
}
