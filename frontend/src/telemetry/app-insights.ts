import { ApplicationInsights } from "@microsoft/applicationinsights-web";
import { onCLS, onFCP, onINP, onLCP, onTTFB } from "web-vitals";

import type { RuntimeConfig } from "../app/runtime-config";

/**
 * Custom telemetry is allowlisted, not denylisted, so a property added later cannot leak by
 * default. Everything here is either an environment label, a trace correlator, or a count.
 */
const ALLOWED_PROPERTIES = new Set([
  "environment",
  "correlationId",
  "evidenceCount",
  "actionCount",
  "status",
]);

/** The belt to the allowlist's braces, and the rule applied to captured header maps. */
const SENSITIVE_KEY = /prompt|answer|token|amount|cost|authorization|secret/i;

function scrubProperties(bag: Record<string, unknown>, environment: string | undefined): void {
  for (const key of Object.keys(bag)) {
    if (SENSITIVE_KEY.test(key) || !ALLOWED_PROPERTIES.has(key)) {
      delete bag[key];
    }
  }
  if (environment) {
    bag.environment = environment;
  }
}

function scrubHeaders(bag: Record<string, unknown>): void {
  for (const key of Object.keys(bag)) {
    if (SENSITIVE_KEY.test(key)) {
      delete bag[key];
    }
  }
}

function asBag(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null ? (value as Record<string, unknown>) : null;
}

/**
 * Runs on every item before it leaves the browser. Question text, answer text, and any cost
 * figure are dropped here rather than relying on call sites to remember not to attach them:
 * custom properties are allowlisted, and custom measurements are cleared outright.
 */
export function sanitizeTelemetryItem(item: unknown, environment?: string): void {
  const telemetry = asBag(item);
  if (!telemetry) {
    return;
  }

  const data = asBag(telemetry.data);
  if (data) {
    scrubProperties(data, environment);
  }

  const baseData = asBag(telemetry.baseData);
  if (!baseData) {
    return;
  }

  const properties = asBag(baseData.properties);
  if (properties) {
    scrubProperties(properties, environment);
  }
  // Nothing here is meant to carry a number, and an amount would arrive as one.
  const measurements = asBag(baseData.measurements);
  if (measurements) {
    for (const key of Object.keys(measurements)) {
      delete measurements[key];
    }
  }
  for (const headerKey of ["requestHeaders", "responseHeaders"]) {
    const headers = asBag(baseData[headerKey]);
    if (headers) {
      scrubHeaders(headers);
    }
  }
}

/** The API is a different origin, so correlation headers only travel if its host is named. */
function apiCorrelationDomains(apiBaseUrl: string): string[] {
  try {
    return [new URL(apiBaseUrl).host];
  } catch {
    return [];
  }
}

/** Kept so a failure can be reported from anywhere without threading the client through. */
let activeClient: ApplicationInsights | undefined;

/**
 * Telemetry is opt-in through configuration: without a connection string nothing is constructed,
 * so a local or air-gapped run sends no browser data at all.
 */
export function initAppInsights(config: RuntimeConfig): ApplicationInsights | undefined {
  if (!config.appInsightsConnectionString) {
    return undefined;
  }

  const client = new ApplicationInsights({
    config: {
      connectionString: config.appInsightsConnectionString,
      // The dashboard is a single page; without this only the first load is ever a page view.
      enableAutoRouteTracking: true,
      // Failed API calls are the signal worth having, so dependency tracking stays on.
      disableAjaxTracking: false,
      disableFetchTracking: false,
      // The API is cross-origin, so without these the browser call and the server span it
      // caused are two unrelated records. The backend already accepts and continues the trace.
      enableCorsCorrelation: true,
      correlationHeaderDomains: apiCorrelationDomains(config.apiBaseUrl),
      // Headers carry the bearer token. They are scrubbed below as well, but not collecting
      // them is the stronger guarantee.
      enableRequestHeaderTracking: false,
      enableResponseHeaderTracking: false,
      disableCookiesUsage: true,
    },
  });

  client.loadAppInsights();
  client.addTelemetryInitializer((item) => {
    sanitizeTelemetryItem(item, config.environment);
  });
  activeClient = client;

  return client;
}

/**
 * The one event the app raises itself. Only the correlator and the status code are sent, so a
 * failure can be joined to its server-side span without carrying the request or the reply.
 */
export function trackApiFailure({
  correlationId,
  status,
}: {
  correlationId: string;
  status?: number;
}): void {
  if (!activeClient) {
    return;
  }
  activeClient.trackEvent(
    { name: "api_failure" },
    status === undefined ? { correlationId } : { correlationId, status },
  );
}

/** Field performance for the charts: no-op when telemetry is not configured. */
export function trackWebVitals(client: ApplicationInsights | undefined): void {
  if (!client) {
    return;
  }
  const report = (metric: { name: string; value: number }) => {
    client.trackMetric({ name: `web-vitals/${metric.name}`, average: metric.value });
  };
  for (const observe of [onCLS, onFCP, onINP, onLCP, onTTFB]) {
    observe(report);
  }
}
