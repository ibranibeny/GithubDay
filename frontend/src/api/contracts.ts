export type CostMetric = "ActualCost" | "AmortizedCost";

export type CostGrouping = "ServiceName" | "ResourceGroupName" | "ResourceId" | "Tag";

export interface CostFilter {
  from: string;
  to: string;
  metric: CostMetric;
  grouping: CostGrouping;
  tagKey?: string;
}

export interface CostPoint {
  date: string;
  amount: number;
  currency: string;
}

export function normalizeCurrency(currencies: string[]): string {
  const unique = new Set(currencies);
  if (unique.size !== 1) {
    throw new Error("Mixed currencies are not supported");
  }
  return currencies[0];
}
