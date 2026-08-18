import { afterEach, describe, expect, it, vi } from "vitest";

import { initAppInsights, sanitizeTelemetryItem, trackWebVitals } from "./app-insights";

const hoisted = vi.hoisted(() => {
  const instances: {
    config: Record<string, unknown>;
    loadAppInsights: ReturnType<typeof vi.fn>;
    addTelemetryInitializer: ReturnType<typeof vi.fn>;
    trackMetric: ReturnType<typeof vi.fn>;
  }[] = [];

  const ApplicationInsights = vi.fn(function (options: { config: Record<string, unknown> }) {
    const instance = {
      config: options.config,
      loadAppInsights: vi.fn(),
      addTelemetryInitializer: vi.fn(),
      trackMetric: vi.fn(),
    };
    instances.push(instance);
    return instance;
  });

  const webVitals = {
    onCLS: vi.fn(),
    onFCP: vi.fn(),
    onINP: vi.fn(),
    onLCP: vi.fn(),
    onTTFB: vi.fn(),
  };

  return { instances, ApplicationInsights, webVitals };
});

vi.mock("@microsoft/applicationinsights-web", () => ({
  ApplicationInsights: hoisted.ApplicationInsights,
}));

vi.mock("web-vitals", () => hoisted.webVitals);

const CONNECTION_STRING = "InstrumentationKey=00000000-0000-0000-0000-000000000000";

const BASE_CONFIG = {
  tenantId: "tenant",
  spaClientId: "spa",
  apiClientId: "api",
  apiBaseUrl: "https://api.example.test",
};

afterEach(() => {
  hoisted.instances.length = 0;
  hoisted.ApplicationInsights.mockClear();
  for (const report of Object.values(hoisted.webVitals)) {
    report.mockClear();
  }
});

describe("initAppInsights", () => {
  it("sends nothing when no connection string is configured", () => {
    expect(initAppInsights({ ...BASE_CONFIG, environment: "workshop" })).toBeUndefined();
    expect(hoisted.ApplicationInsights).not.toHaveBeenCalled();
  });

  it("tracks SPA route changes and API dependencies", () => {
    const client = initAppInsights({
      ...BASE_CONFIG,
      environment: "workshop",
      appInsightsConnectionString: CONNECTION_STRING,
    });

    expect(client).toBeDefined();
    const instance = hoisted.instances[0];
    expect(instance.config.connectionString).toBe(CONNECTION_STRING);
    expect(instance.config.enableAutoRouteTracking).toBe(true);
    expect(instance.config.disableAjaxTracking).toBe(false);
    expect(instance.config.disableFetchTracking).toBe(false);
    expect(instance.loadAppInsights).toHaveBeenCalledTimes(1);
    expect(instance.addTelemetryInitializer).toHaveBeenCalledTimes(1);
  });

  it("registers an initializer that strips prompts, answers, and credentials", () => {
    initAppInsights({
      ...BASE_CONFIG,
      environment: "workshop",
      appInsightsConnectionString: CONNECTION_STRING,
    });
    const initializer = hoisted.instances[0].addTelemetryInitializer.mock.calls[0][0] as (
      item: unknown,
    ) => void;

    const item: {
      name: string;
      data: Record<string, unknown>;
      baseData: {
        properties: Record<string, unknown>;
        requestHeaders: Record<string, unknown>;
      };
    } = {
      name: "dependency",
      data: {
        prompt: "why did my cost rise",
        Answer: "because App Service grew",
        accessToken: "eyJ0",
        amount: 1620.4,
        totalCost: 4200,
        Authorization: "Bearer eyJ0",
        clientSecret: "s3cret",
        correlationId: "correlation-1",
        evidenceCount: 2,
        actionCount: 1,
        status: 200,
      },
      baseData: {
        properties: { prompt: "why did my cost rise", correlationId: "correlation-1" },
        requestHeaders: { Authorization: "Bearer eyJ0", "x-correlation-id": "correlation-1" },
      },
    };

    initializer(item);

    expect(Object.keys(item.data).sort()).toEqual([
      "actionCount",
      "correlationId",
      "environment",
      "evidenceCount",
      "status",
    ]);
    expect(item.data.environment).toBe("workshop");
    expect(item.baseData.properties).toEqual({
      correlationId: "correlation-1",
      environment: "workshop",
    });
    expect(item.baseData.requestHeaders).toEqual({ "x-correlation-id": "correlation-1" });
  });
});

describe("trackWebVitals", () => {
  it("does nothing without a client", () => {
    expect(() => trackWebVitals(undefined)).not.toThrow();
    expect(hoisted.webVitals.onLCP).not.toHaveBeenCalled();
  });

  it("reports each web vital as a metric", () => {
    const client = initAppInsights({
      ...BASE_CONFIG,
      appInsightsConnectionString: CONNECTION_STRING,
    });
    trackWebVitals(client);

    for (const report of Object.values(hoisted.webVitals)) {
      expect(report).toHaveBeenCalledTimes(1);
    }

    const onLcp = hoisted.webVitals.onLCP.mock.calls[0][0] as (metric: unknown) => void;
    onLcp({ name: "LCP", value: 1234.5 });
    expect(hoisted.instances[0].trackMetric).toHaveBeenCalledWith({
      name: "web-vitals/LCP",
      average: 1234.5,
    });
  });
});

describe("sanitizeTelemetryItem", () => {
  it("leaves telemetry without custom data untouched", () => {
    const item = { name: "pageView" };
    expect(() => sanitizeTelemetryItem(item, "workshop")).not.toThrow();
    expect(item).toEqual({ name: "pageView" });
  });
});
