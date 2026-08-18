import { getRuntimeConfig } from "../app/runtime-config";

export const CORRELATION_ID_HEADER = "x-correlation-id";

export type TokenProvider = () => Promise<string>;

export class ApiError extends Error {
  readonly correlationId: string;

  constructor(message: string, correlationId: string) {
    super(message);
    this.name = "ApiError";
    this.correlationId = correlationId;
  }
}

export class ApiHttpError extends ApiError {
  readonly status: number;

  constructor(status: number, correlationId: string) {
    super(`API request failed with status ${status}`, correlationId);
    this.name = "ApiHttpError";
    this.status = status;
  }
}

export class ApiUnauthorizedError extends ApiHttpError {
  constructor(correlationId: string) {
    super(401, correlationId);
    this.name = "ApiUnauthorizedError";
  }
}

export class ApiForbiddenError extends ApiHttpError {
  constructor(correlationId: string) {
    super(403, correlationId);
    this.name = "ApiForbiddenError";
  }
}

export class ApiNetworkError extends ApiError {
  constructor(correlationId: string) {
    super("API request could not reach the server", correlationId);
    this.name = "ApiNetworkError";
  }
}

/** A 2xx the client cannot read. The body is never quoted: it may carry account data. */
export class ApiParseError extends ApiError {
  constructor(correlationId: string, reason: string) {
    super(`API response could not be parsed: ${reason}`, correlationId);
    this.name = "ApiParseError";
  }
}

export interface ApiFetchOptions {
  method?: string;
  body?: unknown;
  correlationId?: string;
  signal?: AbortSignal;
}

/**
 * `crypto.randomUUID` is restricted to secure contexts, so a plain-http origin (a LAN
 * preview, a proxy that terminates TLS elsewhere) would otherwise throw before every
 * request. The value is a trace correlator, never a token or a nonce.
 */
function newCorrelationId(): string {
  const webCrypto = typeof crypto === "undefined" ? undefined : crypto;
  if (typeof webCrypto?.randomUUID === "function") {
    return webCrypto.randomUUID();
  }

  const bytes = new Uint8Array(16);
  if (typeof webCrypto?.getRandomValues === "function") {
    webCrypto.getRandomValues(bytes);
  } else {
    for (let index = 0; index < bytes.length; index += 1) {
      bytes[index] = Math.floor(Math.random() * 256);
    }
  }
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // RFC 4122 version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // RFC 4122 variant 1

  const hex = Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
  return [
    hex.slice(0, 8),
    hex.slice(8, 12),
    hex.slice(12, 16),
    hex.slice(16, 20),
    hex.slice(20),
  ].join("-");
}

export async function apiFetch<T = unknown>(
  path: string,
  tokenProvider: TokenProvider,
  options: ApiFetchOptions = {},
): Promise<T> {
  const { apiBaseUrl } = getRuntimeConfig();
  const correlationId = options.correlationId ?? newCorrelationId();
  const url = `${apiBaseUrl.replace(/\/+$/, "")}/${path.replace(/^\/+/, "")}`;

  const token = await tokenProvider();
  const headers: Record<string, string> = {
    Accept: "application/json",
    Authorization: `Bearer ${token}`,
    [CORRELATION_ID_HEADER]: correlationId,
  };
  if (options.body !== undefined) {
    headers["Content-Type"] = "application/json";
  }

  let response: Response;
  try {
    response = await fetch(url, {
      method: options.method ?? "GET",
      headers,
      body: options.body === undefined ? undefined : JSON.stringify(options.body),
      credentials: "omit",
      mode: "cors",
      signal: options.signal,
    });
  } catch {
    // The transport error can echo the request, including its Authorization header, so it is
    // deliberately dropped rather than chained onto the surfaced error.
    throw new ApiNetworkError(correlationId);
  }

  if (!response.ok) {
    if (response.status === 401) {
      throw new ApiUnauthorizedError(correlationId);
    }
    if (response.status === 403) {
      throw new ApiForbiddenError(correlationId);
    }
    throw new ApiHttpError(response.status, correlationId);
  }

  if (response.status === 204) {
    return undefined as T;
  }
  // A non-JSON 200 is a proxy or gateway answering in the API's place. Resolving it as
  // undefined would hand the caller a hole to dereference later; failing here is louder.
  if (!(response.headers.get("content-type") ?? "").includes("application/json")) {
    throw new ApiParseError(correlationId, "unexpected content type");
  }
  try {
    return (await response.json()) as T;
  } catch {
    // SyntaxError quotes the offending body, so it is dropped rather than chained.
    throw new ApiParseError(correlationId, "malformed JSON body");
  }
}
