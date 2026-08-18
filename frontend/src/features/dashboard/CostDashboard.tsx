import { ShieldAlert } from "lucide-react";
import { useState } from "react";

import type { CostFilter, CostGrouping } from "../../api/contracts";
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
  toCsv,
  useCostData,
} from "./useCostData";

export interface CostDashboardProps {
  subscriptionName: string;
  initialFilter?: CostFilter;
}

export function CostDashboard({ subscriptionName, initialFilter }: CostDashboardProps) {
  const [filter, setFilter] = useState<CostFilter>(() => initialFilter ?? defaultCostFilter());
  const { summary, trend, breakdowns, currency, forbidden, isFetching, refresh } =
    useCostData(filter);

  const points = trend.data?.points ?? [];
  const focusDimension = (dimension: CostGrouping) => {
    setFilter((current) => ({ ...current, grouping: dimension, tagKey: undefined }));
  };

  return (
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

      <CostFilters filter={filter} subscriptionName={subscriptionName} onChange={setFilter} />

      {forbidden ? (
        <AccessRequired />
      ) : (
        <>
          <KpiStrip
            summary={summary.data}
            isPending={summary.isPending}
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
            onFocusDimension={focusDimension}
          />
        </>
      )}
    </div>
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
