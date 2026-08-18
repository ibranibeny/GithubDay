import {
  BrowserCacheLocation,
  InteractionRequiredAuthError,
  type AccountInfo,
  type AuthenticationResult,
  type IPublicClientApplication,
} from "@azure/msal-browser";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import type { RuntimeConfig } from "../app/runtime-config";
import {
  InteractiveAuthRequiredError,
  acquireAccessToken,
  buildApiScope,
  buildMsalConfig,
} from "./msal";

const TOKEN = "eyJ-super-secret-access-token";

const config: RuntimeConfig = {
  tenantId: "11111111-1111-1111-1111-111111111111",
  spaClientId: "22222222-2222-2222-2222-222222222222",
  apiClientId: "33333333-3333-3333-3333-333333333333",
  apiBaseUrl: "https://api.example.com",
};

const account = {
  homeAccountId: "home",
  environment: "login.microsoftonline.com",
  tenantId: config.tenantId,
  username: "user@contoso.com",
  localAccountId: "local",
} as AccountInfo;

interface FakeInstance {
  getActiveAccount: ReturnType<typeof vi.fn>;
  getAllAccounts: ReturnType<typeof vi.fn>;
  acquireTokenSilent: ReturnType<typeof vi.fn>;
  acquireTokenRedirect: ReturnType<typeof vi.fn>;
}

let fake: FakeInstance;

function asInstance(instance: FakeInstance): IPublicClientApplication {
  return instance as unknown as IPublicClientApplication;
}

beforeEach(() => {
  fake = {
    getActiveAccount: vi.fn(() => account),
    getAllAccounts: vi.fn(() => [account]),
    acquireTokenSilent: vi.fn(() =>
      Promise.resolve({ accessToken: TOKEN } as AuthenticationResult),
    ),
    acquireTokenRedirect: vi.fn(() => Promise.resolve()),
  };
});

afterEach(() => {
  vi.restoreAllMocks();
  window.localStorage.clear();
  window.sessionStorage.clear();
});

describe("buildApiScope", () => {
  it("targets the access_as_user scope of the API app registration", () => {
    expect(buildApiScope(config)).toBe("api://33333333-3333-3333-3333-333333333333/access_as_user");
  });
});

describe("buildMsalConfig", () => {
  it("uses the configured tenant authority and SPA client ID", () => {
    const msalConfig = buildMsalConfig(config);

    expect(msalConfig.auth.clientId).toBe("22222222-2222-2222-2222-222222222222");
    expect(msalConfig.auth.authority).toBe(
      "https://login.microsoftonline.com/11111111-1111-1111-1111-111111111111",
    );
  });

  it("never caches tokens in localStorage", () => {
    const msalConfig = buildMsalConfig(config);

    expect(msalConfig.cache?.cacheLocation).toBe(BrowserCacheLocation.SessionStorage);
    expect(msalConfig.cache?.cacheLocation).not.toBe(BrowserCacheLocation.LocalStorage);
  });

  it("disables PII logging", () => {
    const msalConfig = buildMsalConfig(config);

    expect(msalConfig.system?.loggerOptions?.piiLoggingEnabled).toBe(false);
  });
});

describe("acquireAccessToken", () => {
  it("returns the silently acquired access token", async () => {
    const token = await acquireAccessToken(asInstance(fake), config);

    expect(token).toBe(TOKEN);
    expect(fake.acquireTokenSilent).toHaveBeenCalledWith(
      expect.objectContaining({
        scopes: ["api://33333333-3333-3333-3333-333333333333/access_as_user"],
        account,
      }),
    );
    expect(fake.acquireTokenRedirect).not.toHaveBeenCalled();
  });

  it("falls back to a redirect when interaction is required", async () => {
    fake.acquireTokenSilent.mockRejectedValue(
      new InteractionRequiredAuthError("interaction_required", "correlation-id"),
    );

    const error = await acquireAccessToken(asInstance(fake), config).catch((e: unknown) => e);

    expect(error).toBeInstanceOf(InteractiveAuthRequiredError);
    expect(fake.acquireTokenRedirect).toHaveBeenCalledWith(
      expect.objectContaining({
        scopes: ["api://33333333-3333-3333-3333-333333333333/access_as_user"],
      }),
    );
  });

  it("does not redirect for non-interactive failures", async () => {
    fake.acquireTokenSilent.mockRejectedValue(new Error("network down"));

    await expect(acquireAccessToken(asInstance(fake), config)).rejects.toThrow("network down");
    expect(fake.acquireTokenRedirect).not.toHaveBeenCalled();
  });

  it("falls back to the first known account when none is active", async () => {
    fake.getActiveAccount.mockReturnValue(null);

    await acquireAccessToken(asInstance(fake), config);

    expect(fake.acquireTokenSilent).toHaveBeenCalledWith(expect.objectContaining({ account }));
  });

  it("never persists the token in app-owned storage or the console", async () => {
    const consoleSpies = (["log", "info", "warn", "error", "debug"] as const).map((level) =>
      vi.spyOn(console, level).mockImplementation(() => {}),
    );

    await acquireAccessToken(asInstance(fake), config);

    expect(JSON.stringify(window.localStorage)).not.toContain(TOKEN);
    expect(JSON.stringify(window.sessionStorage)).not.toContain(TOKEN);
    for (const spy of consoleSpies) {
      expect(spy.mock.calls.flat().some((arg) => String(arg).includes(TOKEN))).toBe(false);
    }
  });
});
