import { z } from "zod";

export const costMetricSchema = z.enum(["ActualCost", "AmortizedCost"]);
export type CostMetric = z.infer<typeof costMetricSchema>;

export const costGroupingSchema = z.enum(["ServiceName", "ResourceGroupName", "ResourceId", "Tag"]);
export type CostGrouping = z.infer<typeof costGroupingSchema>;

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

/** The API speaks whole days; a timestamp here would silently shift the window by a timezone. */
const isoDateSchema = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "must be a YYYY-MM-DD date");

export const evidenceSchema = z.object({
  metric: costMetricSchema,
  dimension: z.string().min(1),
  periodStart: isoDateSchema,
  periodEnd: isoDateSchema,
  amount: z.number().finite(),
});

export type Evidence = z.infer<typeof evidenceSchema>;

export const chartActionSchema = z.object({
  kind: z.enum(["set-filter", "highlight-series"]),
  metric: costMetricSchema.optional(),
  grouping: costGroupingSchema.optional(),
  value: z.string().min(1).optional(),
  start: isoDateSchema.optional(),
  end: isoDateSchema.optional(),
});

export type ChartAction = z.infer<typeof chartActionSchema>;

export const chatResponseSchema = z.object({
  answer: z.string(),
  evidence: z.array(evidenceSchema),
  chartActions: z.array(chartActionSchema),
  explanationAvailable: z.boolean(),
});

export type ChatResponse = z.infer<typeof chatResponseSchema>;

export interface ChatRequest {
  prompt: string;
  filters: CostFilter;
}

/** The reply may quote account data, so only the failing field paths are surfaced. */
export class ChatResponseError extends Error {
  readonly fields: string[];

  constructor(fields: string[]) {
    super(`The assistant reply did not match the expected shape: ${fields.join(", ")}`);
    this.name = "ChatResponseError";
    this.fields = fields;
  }
}

export function parseChatResponse(raw: unknown): ChatResponse {
  const result = chatResponseSchema.safeParse(raw);
  if (!result.success) {
    const fields = [...new Set(result.error.issues.map((issue) => issue.path.join(".")))];
    throw new ChatResponseError(fields.length > 0 ? fields : ["response"]);
  }
  return result.data;
}

/**
 * A second gate in front of anything that moves the dashboard. The schema already rejects a
 * malformed reply, but an action can also arrive from a replayed payload or from a future server
 * that learned a verb this build does not implement.
 */
export function isChartAction(value: unknown): value is ChartAction {
  return chartActionSchema.safeParse(value).success;
}

export function isEvidence(value: unknown): value is Evidence {
  return evidenceSchema.safeParse(value).success;
}
