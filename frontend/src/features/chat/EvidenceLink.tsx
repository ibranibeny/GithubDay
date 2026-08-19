import type { Evidence } from "../../api/contracts";
import { formatCurrency } from "../dashboard/format";
import { METRIC_LABELS } from "../dashboard/useCostData";

export interface EvidenceLinkProps {
  evidence: Evidence;
  currency: string;
  onApply: (evidence: Evidence) => void;
}

/**
 * A citation the reader can act on: it names the exact figure the answer leaned on, and applying
 * it moves the dashboard to the same window so the claim can be checked against the charts.
 */
export function EvidenceLink({ evidence, currency, onApply }: EvidenceLinkProps) {
  const metricLabel = METRIC_LABELS[evidence.metric];

  return (
    <button
      type="button"
      className="evidence"
      aria-label={`Apply ${metricLabel} for ${evidence.dimension}, ${evidence.periodStart} to ${evidence.periodEnd}`}
      onClick={() => onApply(evidence)}
    >
      <span className="evidence__dimension">{evidence.dimension}</span>
      <span className="evidence__amount num">{formatCurrency(evidence.amount, currency)}</span>
      <span className="evidence__period num">
        {metricLabel} · {evidence.periodStart} to {evidence.periodEnd}
      </span>
    </button>
  );
}
