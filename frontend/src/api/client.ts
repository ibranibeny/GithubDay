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

export interface ApiFetchOptions {
  method?: string;
  body?: unknown;
  correlationId?: string;
}

export async function apiFetch<T = unknown>(
  path: string,
  tokenProvider: TokenProvider,
  options: ApiFetchOptions = {},
): Promise<T> {
  const { apiBaseUrl } = getRuntimeConfig();
  const correlationId = options.correlationId ?? crypto.randomUUID();
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
  if (!(response.headers.get("content-type") ?? "").includes("application/json")) {
    return undefined as T;
  }
  return (await response.json()) as T;
}
