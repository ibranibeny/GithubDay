import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import {
  ApiError,
  ApiForbiddenError,
  ApiHttpError,
  ApiNetworkError,
  ApiParseError,
  ApiUnauthorizedError,
  CORRELATION_ID_HEADER,
  apiFetch,
} from "./client";

const TOKEN = "eyJ-super-secret-access-token";
const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

const runtimeConfig = {
  tenantId: "11111111-1111-1111-1111-111111111111",
  spaClientId: "22222222-2222-2222-2222-222222222222",
  apiClientId: "33333333-3333-3333-3333-333333333333",
  apiBaseUrl: "https://api.example.com/",
};

const tokenProvider = () => Promise.resolve(TOKEN);

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

let fetchMock: ReturnType<typeof vi.fn>;

beforeEach(() => {
  window.__APP_CONFIG__ = runtimeConfig;
  fetchMock = vi.fn();
  vi.stubGlobal("fetch", fetchMock);
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
  delete window.__APP_CONFIG__;
  window.localStorage.clear();
  window.sessionStorage.clear();
});

describe("apiFetch", () => {
  it("adds a bearer token and correlation ID", async () => {
    fetchMock.mockResolvedValue(jsonResponse({ total: 12 }));

    const result = await apiFetch<{ total: number }>("/api/costs/summary", tokenProvider);

    expect(result).toEqual({ total: 12 });
    expect(fetchMock).toHaveBeenCalledWith(
      "https://api.example.com/api/costs/summary",
      expect.objectContaining({
        headers: expect.objectContaining({ Authorization: `Bearer ${TOKEN}` }),
      }),
    );

    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    const headers = init.headers as Record<string, string>;
    expect(headers[CORRELATION_ID_HEADER]).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i,
    );
    expect(headers.Accept).toBe("application/json");
  });

  it("issues a distinct correlation ID per request", async () => {
    fetchMock.mockImplementation(() => Promise.resolve(jsonResponse({})));

    await apiFetch("/api/costs/summary", tokenProvider);
    await apiFetch("/api/costs/summary", tokenProvider);

    const correlationIds = fetchMock.mock.calls.map(
      (call) => ((call[1] as RequestInit).headers as Record<string, string>)[CORRELATION_ID_HEADER],
    );
    expect(new Set(correlationIds).size).toBe(2);
  });

  it("serialises a JSON body", async () => {
    fetchMock.mockResolvedValue(jsonResponse({}));

    await apiFetch("/api/chat", tokenProvider, { method: "POST", body: { question: "why" } });

    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(init.method).toBe("POST");
    expect(init.body).toBe(JSON.stringify({ question: "why" }));
    expect((init.headers as Record<string, string>)["Content-Type"]).toBe("application/json");
  });

  it("maps 401 to a typed unauthorized error", async () => {
    fetchMock.mockResolvedValue(jsonResponse({ detail: "no" }, 401));

    const error = await apiFetch("/api/costs/summary", tokenProvider).catch((e: unknown) => e);

    expect(error).toBeInstanceOf(ApiUnauthorizedError);
    expect((error as ApiHttpError).status).toBe(401);
    expect((error as ApiError).correlationId).toBeTruthy();
  });

  it("maps 403 to a typed forbidden error", async () => {
    fetchMock.mockResolvedValue(jsonResponse({ detail: "no" }, 403));

    const error = await apiFetch("/api/costs/summary", tokenProvider).catch((e: unknown) => e);

    expect(error).toBeInstanceOf(ApiForbiddenError);
    expect((error as ApiHttpError).status).toBe(403);
  });

  it("maps other failures to a typed HTTP error", async () => {
    fetchMock.mockResolvedValue(jsonResponse({ detail: "boom" }, 503));

    const error = await apiFetch("/api/costs/summary", tokenProvider).catch((e: unknown) => e);

    expect(error).toBeInstanceOf(ApiHttpError);
    expect(error).not.toBeInstanceOf(ApiUnauthorizedError);
    expect((error as ApiHttpError).status).toBe(503);
  });

  it("maps transport failures to a typed network error", async () => {
    fetchMock.mockRejectedValue(new TypeError("Failed to fetch"));

    const error = await apiFetch("/api/costs/summary", tokenProvider).catch((e: unknown) => e);

    expect(error).toBeInstanceOf(ApiNetworkError);
    expect(error).toBeInstanceOf(ApiError);
  });

  it("returns undefined for an empty 204 response", async () => {
    fetchMock.mockResolvedValue(new Response(null, { status: 204 }));

    await expect(apiFetch("/api/costs/summary", tokenProvider)).resolves.toBeUndefined();
  });

  it("forwards an abort signal to fetch", async () => {
    const controller = new AbortController();
    fetchMock.mockResolvedValue(jsonResponse({}));

    await apiFetch("/api/costs/summary", tokenProvider, { signal: controller.signal });

    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(init.signal).toBe(controller.signal);
  });

  it("maps a malformed JSON body to a typed parse error", async () => {
    fetchMock.mockResolvedValue(
      new Response("{ not json at all", {
        status: 200,
        headers: { "content-type": "application/json" },
      }),
    );

    const error = await apiFetch("/api/costs/summary", tokenProvider).catch((e: unknown) => e);

    expect(error).toBeInstanceOf(ApiParseError);
    expect(error).toBeInstanceOf(ApiError);
    expect(error).not.toBeInstanceOf(SyntaxError);
    expect((error as ApiError).correlationId).toBeTruthy();
    expect((error as Error).message).not.toContain("not json at all");
  });

  it("rejects a 200 that is not JSON instead of resolving undefined", async () => {
    fetchMock.mockResolvedValue(
      new Response("<html>gateway sign-in page</html>", {
        status: 200,
        headers: { "content-type": "text/html" },
      }),
    );

    const error = await apiFetch("/api/costs/summary", tokenProvider).catch((e: unknown) => e);

    expect(error).toBeInstanceOf(ApiParseError);
    expect((error as Error).message).not.toContain("gateway sign-in page");
  });

  it("mints a correlation ID when crypto.randomUUID is unavailable", async () => {
    vi.stubGlobal("crypto", {
      getRandomValues: (array: Uint8Array) => {
        for (let index = 0; index < array.length; index += 1) {
          array[index] = index * 11;
        }
        return array;
      },
    });
    fetchMock.mockResolvedValue(jsonResponse({}));

    await apiFetch("/api/costs/summary", tokenProvider);

    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect((init.headers as Record<string, string>)[CORRELATION_ID_HEADER]).toMatch(UUID_V4);
  });

  it("mints a correlation ID when Web Crypto is missing entirely", async () => {
    vi.stubGlobal("crypto", undefined);
    fetchMock.mockResolvedValue(jsonResponse({}));

    await apiFetch("/api/costs/summary", tokenProvider);

    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect((init.headers as Record<string, string>)[CORRELATION_ID_HEADER]).toMatch(UUID_V4);
  });

  it("never leaks the token to the console, storage, or the error surface", async () => {
    const consoleSpies = (["log", "info", "warn", "error", "debug"] as const).map((level) =>
      vi.spyOn(console, level).mockImplementation(() => {}),
    );
    fetchMock.mockResolvedValue(jsonResponse({ detail: "no" }, 401));

    const error = await apiFetch("/api/costs/summary", tokenProvider).catch((e: unknown) => e);

    for (const spy of consoleSpies) {
      const leaked = spy.mock.calls.flat().some((arg) => String(arg).includes(TOKEN));
      expect(leaked).toBe(false);
    }
    expect(JSON.stringify(window.localStorage)).not.toContain(TOKEN);
    expect(JSON.stringify(window.sessionStorage)).not.toContain(TOKEN);
    expect(String((error as Error).message)).not.toContain(TOKEN);
    expect(String((error as Error).stack)).not.toContain(TOKEN);
  });

  it("fails closed when the runtime configuration is missing", async () => {
    delete window.__APP_CONFIG__;

    await expect(apiFetch("/api/costs/summary", tokenProvider)).rejects.toThrow();
    expect(fetchMock).not.toHaveBeenCalled();
  });
});
