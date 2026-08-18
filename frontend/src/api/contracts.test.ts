import { describe, expect, it } from "vitest";

import {
  ChatResponseError,
  chartActionSchema,
  evidenceSchema,
  normalizeCurrency,
  parseChatResponse,
} from "./contracts";

const REPLY = {
  answer: "App Service is the largest driver.",
  evidence: [
    {
      metric: "ActualCost",
      dimension: "Azure App Service",
      periodStart: "2026-07-01",
      periodEnd: "2026-07-31",
      amount: 1620.4,
    },
  ],
  chartActions: [{ kind: "highlight-series", grouping: "ServiceName", value: "Azure App Service" }],
  explanationAvailable: true,
};

function caught(run: () => unknown): unknown {
  try {
    run();
    return null;
  } catch (error: unknown) {
    return error;
  }
}

describe("normalizeCurrency", () => {
  it("rejects a response with mixed currencies", () => {
    expect(() => normalizeCurrency(["USD", "IDR"])).toThrow("Mixed currencies");
  });
});

describe("parseChatResponse", () => {
  it("returns the reply when it matches the contract", () => {
    expect(parseChatResponse(REPLY)).toEqual(REPLY);
  });

  it("names only the failing field paths, never the value that failed", () => {
    const error = caught(() =>
      parseChatResponse({
        ...REPLY,
        answer: 42,
        evidence: [{ ...REPLY.evidence[0], amount: "why did my cost rise" }],
      }),
    );

    expect(error).toBeInstanceOf(ChatResponseError);
    const failure = error as ChatResponseError;
    expect(failure.fields).toEqual(["answer", "evidence.0.amount"]);
    expect(failure.message).toContain("evidence.0.amount");
    expect(failure.message).not.toContain("why did my cost rise");
    expect(failure.message).not.toContain("42");
  });

  it("reports the response itself when the payload is not an object", () => {
    expect((caught(() => parseChatResponse("not a reply")) as ChatResponseError).fields).toEqual([
      "response",
    ]);
  });

  it("rejects an answer longer than the API can return", () => {
    expect(() => parseChatResponse({ ...REPLY, answer: "a".repeat(4001) })).toThrow(
      ChatResponseError,
    );
    expect(() => parseChatResponse({ ...REPLY, answer: "a".repeat(4000) })).not.toThrow();
  });

  it("rejects an evidence dimension longer than the API can return", () => {
    const item = REPLY.evidence[0];
    expect(evidenceSchema.safeParse({ ...item, dimension: "d".repeat(513) }).success).toBe(false);
    expect(evidenceSchema.safeParse({ ...item, dimension: "d".repeat(512) }).success).toBe(true);
  });

  it("keeps a chart action value bounded as well", () => {
    expect(
      chartActionSchema.safeParse({ kind: "highlight-series", value: "v".repeat(513) }).success,
    ).toBe(false);
  });
});
