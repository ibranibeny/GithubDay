import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { act, renderHook, waitFor } from "@testing-library/react";
import type { ReactNode } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { ApiHttpError } from "../../api/client";
import type { ChatResponse, CostFilter } from "../../api/contracts";
import {
  ChatGatewayContext,
  liveChatGateway,
  useCostChat,
  type ChatGateway,
  type ChatSendOptions,
} from "./useCostChat";

const hoisted = vi.hoisted(() => ({ trackApiFailure: vi.fn() }));

vi.mock("../../auth/msal", () => ({ getAccessToken: () => Promise.resolve("token") }));
vi.mock("../../telemetry/app-insights", () => ({ trackApiFailure: hoisted.trackApiFailure }));

const FILTER: CostFilter = {
  from: "2026-08-01",
  to: "2026-08-31",
  metric: "ActualCost",
  grouping: "ServiceName",
};

const REPLY: ChatResponse = {
  answer: "App Service is the largest driver.",
  evidence: [],
  chartActions: [],
  explanationAvailable: true,
};

function wrapperFor(gateway: ChatGateway) {
  const client = new QueryClient({
    defaultOptions: { mutations: { retry: false }, queries: { retry: false } },
  });
  return function Wrapper({ children }: { children: ReactNode }) {
    return (
      <QueryClientProvider client={client}>
        <ChatGatewayContext.Provider value={gateway}>{children}</ChatGatewayContext.Provider>
      </QueryClientProvider>
    );
  };
}

let fetchMock: ReturnType<typeof vi.fn>;

beforeEach(() => {
  window.__APP_CONFIG__ = {
    tenantId: "11111111-1111-1111-1111-111111111111",
    spaClientId: "22222222-2222-2222-2222-222222222222",
    apiClientId: "33333333-3333-3333-3333-333333333333",
    apiBaseUrl: "https://api.example.com",
  };
  fetchMock = vi.fn(() =>
    Promise.resolve(
      new Response(JSON.stringify(REPLY), {
        status: 200,
        headers: { "content-type": "application/json" },
      }),
    ),
  );
  vi.stubGlobal("fetch", fetchMock);
  hoisted.trackApiFailure.mockClear();
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
  delete window.__APP_CONFIG__;
});

function postedBody(): { prompt: string; filters: Record<string, unknown> } {
  const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
  return JSON.parse(init.body as string) as { prompt: string; filters: Record<string, unknown> };
}

describe("liveChatGateway", () => {
  it("posts the date bounds under the names the API accepts", async () => {
    await liveChatGateway.send(
      { prompt: "Why did cost rise?", filters: FILTER },
      { correlationId: "correlation-1" },
    );

    const body = postedBody();
    expect(body.prompt).toBe("Why did cost rise?");
    expect(body.filters).toEqual({
      start: "2026-08-01",
      end: "2026-08-31",
      metric: "ActualCost",
      grouping: "ServiceName",
    });
    expect(body.filters).not.toHaveProperty("from");
    expect(body.filters).not.toHaveProperty("to");
  });

  it("sends the tag key only when the grouping is Tag", async () => {
    await liveChatGateway.send(
      {
        prompt: "Which cost centre?",
        filters: { ...FILTER, grouping: "Tag", tagKey: "costCenter" },
      },
      { correlationId: "correlation-2" },
    );
    expect(postedBody().filters).toEqual({
      start: "2026-08-01",
      end: "2026-08-31",
      metric: "ActualCost",
      grouping: "Tag",
      tagKey: "costCenter",
    });

    fetchMock.mockClear();
    await liveChatGateway.send(
      { prompt: "And by service?", filters: { ...FILTER, tagKey: "costCenter" } },
      { correlationId: "correlation-3" },
    );
    expect(postedBody().filters).not.toHaveProperty("tagKey");
  });
});

describe("useCostChat", () => {
  it("clears the previous answer when a new question is asked", async () => {
    let resolveSecond: ((value: ChatResponse) => void) | undefined;
    const send = vi
      .fn()
      .mockResolvedValueOnce(REPLY)
      .mockImplementationOnce(
        () =>
          new Promise<ChatResponse>((resolve) => {
            resolveSecond = resolve;
          }),
      );
    const { result } = renderHook(() => useCostChat(FILTER), {
      wrapper: wrapperFor({ send }),
    });

    act(() => result.current.send("Why did cost rise?"));
    await waitFor(() => expect(result.current.latest).not.toBeNull());

    act(() => result.current.send("And last month?"));
    await waitFor(() => expect(result.current.isPending).toBe(true));
    expect(result.current.latest).toBeNull();
    expect(resolveSecond).toBeDefined();
  });

  it("aborts the request in flight when a new question is asked", async () => {
    const signals: (AbortSignal | undefined)[] = [];
    const send = vi.fn((_request: unknown, options: ChatSendOptions) => {
      signals.push(options.signal);
      return new Promise<ChatResponse>(() => {});
    });
    const { result, unmount } = renderHook(() => useCostChat(FILTER), {
      wrapper: wrapperFor({ send }),
    });

    act(() => result.current.send("First"));
    await waitFor(() => expect(signals).toHaveLength(1));
    expect(signals[0]).toBeInstanceOf(AbortSignal);
    expect(signals[0]?.aborted).toBe(false);

    act(() => result.current.send("Second"));
    await waitFor(() => expect(signals).toHaveLength(2));
    expect(signals[0]?.aborted).toBe(true);

    unmount();
    expect(signals[1]?.aborted).toBe(true);
  });

  it("reports a failed turn to telemetry with its correlation id and status", async () => {
    let sent = "";
    const send = vi.fn((_request: unknown, options: ChatSendOptions) => {
      sent = options.correlationId;
      return Promise.reject(new ApiHttpError(503, options.correlationId));
    });
    const { result } = renderHook(() => useCostChat(FILTER), {
      wrapper: wrapperFor({ send }),
    });

    act(() => result.current.send("Why did cost rise?"));
    await waitFor(() => expect(result.current.error).not.toBeNull());

    expect(hoisted.trackApiFailure).toHaveBeenCalledWith({ correlationId: sent, status: 503 });
  });
});
