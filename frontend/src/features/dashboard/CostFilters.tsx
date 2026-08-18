import { SlidersHorizontal, X } from "lucide-react";
import { useId, useState, type FormEvent } from "react";

import type { CostFilter, CostGrouping, CostMetric } from "../../api/contracts";
import { formatMonthLabel } from "./format";
import { DIMENSION_LABELS, METRIC_LABELS, monthFilter } from "./useCostData";

const SELECTABLE_DIMENSIONS: CostGrouping[] = ["ServiceName", "ResourceGroupName", "ResourceId"];
const MONTH_CHOICES = 6;

function monthsEndingAt(month: string, count: number): string[] {
  const [year, index] = month.split("-").map(Number);
  const months: string[] = [];
  for (let step = count - 1; step >= 0; step -= 1) {
    const date = new Date(Date.UTC(year, index - 1 - step, 1));
    months.push(`${date.getUTCFullYear()}-${String(date.getUTCMonth() + 1).padStart(2, "0")}`);
  }
  return months;
}

export interface CostFiltersProps {
  filter: CostFilter;
  subscriptionName: string;
  onChange: (next: CostFilter) => void;
}

/**
 * One fixed-height strip. Every control here changes a query parameter the API actually accepts,
 * so there is no decorative "view" dropdown with a single option -- the view is stated as fact.
 */
export function CostFilters({ filter, subscriptionName, onChange }: CostFiltersProps) {
  const ids = useId();
  const month = filter.from.slice(0, 7);
  const [tagDraft, setTagDraft] = useState("");
  const [tagOpen, setTagOpen] = useState(false);

  const apply = (next: Partial<{ month: string; metric: CostMetric; grouping: CostGrouping }>) => {
    onChange(
      monthFilter(
        next.month ?? month,
        next.metric ?? filter.metric,
        next.grouping ?? filter.grouping,
        filter.grouping === "Tag" ? filter.tagKey : undefined,
      ),
    );
  };

  const applyTag = (event: FormEvent) => {
    event.preventDefault();
    const key = tagDraft.trim();
    if (!key) {
      return;
    }
    onChange(monthFilter(month, filter.metric, "Tag", key));
    setTagOpen(false);
  };

  return (
    <div className="scope">
      <div className="scope__fact">
        <span className="scope__label">Scope</span>
        <span className="scope__value">{subscriptionName}</span>
      </div>
      <div className="scope__fact">
        <span className="scope__label">View</span>
        <span className="scope__value">Accumulated costs</span>
      </div>

      <div className="scope__field">
        <label className="scope__label" htmlFor={`${ids}-period`}>
          Period
        </label>
        <select
          id={`${ids}-period`}
          value={month}
          onChange={(event) => apply({ month: event.target.value })}
        >
          {monthsEndingAt(month, MONTH_CHOICES).map((choice) => (
            <option key={choice} value={choice}>
              {formatMonthLabel(choice)}
            </option>
          ))}
        </select>
      </div>

      <div className="scope__field">
        <label className="scope__label" htmlFor={`${ids}-metric`}>
          Metric
        </label>
        <select
          id={`${ids}-metric`}
          value={filter.metric}
          onChange={(event) => apply({ metric: event.target.value as CostMetric })}
        >
          {Object.entries(METRIC_LABELS).map(([value, label]) => (
            <option key={value} value={value}>
              {label}
            </option>
          ))}
        </select>
      </div>

      <div className="scope__field">
        <label className="scope__label" htmlFor={`${ids}-grouping`}>
          Group by
        </label>
        <select
          id={`${ids}-grouping`}
          value={filter.grouping}
          onChange={(event) => apply({ grouping: event.target.value as CostGrouping })}
        >
          {SELECTABLE_DIMENSIONS.map((dimension) => (
            <option key={dimension} value={dimension}>
              {DIMENSION_LABELS[dimension]}
            </option>
          ))}
          {/* Tag is entered through the filter control, which also supplies the required key. */}
          {filter.grouping === "Tag" ? <option value="Tag">{DIMENSION_LABELS.Tag}</option> : null}
        </select>
      </div>

      {filter.grouping === "Tag" ? (
        <p className="scope__chip">
          <span className="scope__label">Tag</span>
          <span className="num">{filter.tagKey}</span>
          <button
            type="button"
            className="scope__chip-clear"
            onClick={() => apply({ grouping: "ServiceName" })}
          >
            <X size={12} aria-hidden />
            <span className="visually-hidden">Remove the tag filter</span>
          </button>
        </p>
      ) : tagOpen ? (
        <form className="scope__field scope__field--inline" onSubmit={applyTag}>
          <label className="scope__label" htmlFor={`${ids}-tag`}>
            Tag key
          </label>
          <input
            id={`${ids}-tag`}
            value={tagDraft}
            autoComplete="off"
            placeholder="costCenter"
            onChange={(event) => setTagDraft(event.target.value)}
          />
          <button type="submit" className="command command--quiet">
            Apply
          </button>
        </form>
      ) : (
        <button type="button" className="command command--quiet" onClick={() => setTagOpen(true)}>
          <SlidersHorizontal size={14} aria-hidden />
          Add tag filter
        </button>
      )}
    </div>
  );
}
