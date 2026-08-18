import { afterEach, describe, expect, it } from "vitest";

import { RuntimeConfigError, getRuntimeConfig, parseRuntimeConfig } from "./runtime-config";

const validRaw = {
  environment: "dev",
  tenantId: "11111111-1111-1111-1111-111111111111",
  spaClientId: "22222222-2222-2222-2222-222222222222",
  apiClientId: "33333333-3333-3333-3333-333333333333",
  apiBaseUrl: "https://api.example.com",
  appInsightsConnectionString: "InstrumentationKey=00000000-0000-0000-0000-000000000000",
};

afterEach(() => {
  delete window.__APP_CONFIG__;
});

describe("parseRuntimeConfig", () => {
  it("fails closed when the API client ID is missing", () => {
    expect(() => parseRuntimeConfig({ tenantId: "tenant" })).toThrow("apiClientId");
  });

  it("names every missing required field", () => {
    let thrown: unknown;
    try {
      parseRuntimeConfig({ tenantId: "tenant" });
    } catch (error) {
      thrown = error;
    }

    expect(thrown).toBeInstanceOf(RuntimeConfigError);
    expect((thrown as RuntimeConfigError).fields).toEqual([
      "spaClientId",
      "apiClientId",
      "apiBaseUrl",
    ]);
  });

  it("parses a fully populated configuration", () => {
    expect(parseRuntimeConfig(validRaw)).toEqual({
      environment: "dev",
      tenantId: "11111111-1111-1111-1111-111111111111",
      spaClientId: "22222222-2222-2222-2222-222222222222",
      apiClientId: "33333333-3333-3333-3333-333333333333",
      apiBaseUrl: "https://api.example.com",
      appInsightsConnectionString: "InstrumentationKey=00000000-0000-0000-0000-000000000000",
    });
  });

  it("accepts a configuration without the optional fields", () => {
    const config = parseRuntimeConfig({
      tenantId: validRaw.tenantId,
      spaClientId: validRaw.spaClientId,
      apiClientId: validRaw.apiClientId,
      apiBaseUrl: validRaw.apiBaseUrl,
    });

    expect(config.environment).toBeUndefined();
    expect(config.appInsightsConnectionString).toBeUndefined();
    expect(config.apiClientId).toBe("33333333-3333-3333-3333-333333333333");
  });

  it("treats blank optional values as absent", () => {
    const config = parseRuntimeConfig({
      ...validRaw,
      environment: "",
      appInsightsConnectionString: "",
    });

    expect(config.environment).toBeUndefined();
    expect(config.appInsightsConnectionString).toBeUndefined();
  });

  it("ignores unknown extra keys", () => {
    const config = parseRuntimeConfig({ ...validRaw, unexpected: "value" });

    expect(config).not.toHaveProperty("unexpected");
  });

  it("rejects unsubstituted envsubst placeholders", () => {
    expect(() => parseRuntimeConfig({ ...validRaw, apiBaseUrl: "${API_BASE_URL}" })).toThrow(
      "apiBaseUrl",
    );
  });

  it("rejects a non-object configuration", () => {
    expect(() => parseRuntimeConfig("nope")).toThrow(RuntimeConfigError);
  });

  it("rejects an apiBaseUrl that is not an absolute http(s) URL", () => {
    expect(() => parseRuntimeConfig({ ...validRaw, apiBaseUrl: "/relative" })).toThrow(
      "apiBaseUrl",
    );
  });
});

describe("getRuntimeConfig", () => {
  it("reads the configuration injected on window", () => {
    window.__APP_CONFIG__ = validRaw;

    expect(getRuntimeConfig().tenantId).toBe("11111111-1111-1111-1111-111111111111");
  });

  it("fails closed when no configuration was injected", () => {
    expect(() => getRuntimeConfig()).toThrow(RuntimeConfigError);
  });
});
