import {
  BrowserCacheLocation,
  InteractionRequiredAuthError,
  LogLevel,
  PublicClientApplication,
  type Configuration,
  type IPublicClientApplication,
} from "@azure/msal-browser";

import { getRuntimeConfig, type RuntimeConfig } from "../app/runtime-config";

/** Thrown after a redirect has been started; the caller cannot get a token this turn. */
export class InteractiveAuthRequiredError extends Error {
  constructor() {
    super("Interactive sign-in is required; redirecting to Microsoft Entra ID.");
    this.name = "InteractiveAuthRequiredError";
  }
}

export function buildApiScope(config: RuntimeConfig): string {
  return `api://${config.apiClientId}/Cost.Read`;
}

export function buildMsalConfig(config: RuntimeConfig): Configuration {
  return {
    auth: {
      clientId: config.spaClientId,
      authority: `https://login.microsoftonline.com/${config.tenantId}`,
      redirectUri: window.location.origin,
      postLogoutRedirectUri: window.location.origin,
    },
    cache: {
      // sessionStorage scopes MSAL's cache to the tab session so tokens disappear when the tab
      // closes, unlike localStorage which keeps them readable long after the user walks away.
      // memoryStorage is not usable here: the sign-in redirect reloads the page and would drop
      // the PKCE state before the code exchange completes.
      // msal-browser v5 removed storeAuthStateInCookie, so cacheLocation is the only knob left.
      cacheLocation: BrowserCacheLocation.SessionStorage,
    },
    system: {
      loggerOptions: {
        piiLoggingEnabled: false,
        logLevel: LogLevel.Error,
        loggerCallback: (level, message, containsPii) => {
          if (containsPii || level !== LogLevel.Error) {
            return;
          }
          console.error(`[msal] ${message}`);
        },
      },
    },
  };
}

let cachedInstance: PublicClientApplication | null = null;

export function getMsalInstance(
  config: RuntimeConfig = getRuntimeConfig(),
): PublicClientApplication {
  cachedInstance ??= new PublicClientApplication(buildMsalConfig(config));
  return cachedInstance;
}

/**
 * MsalProvider owns initialize() and handleRedirectPromise() for the whole app, so nothing here
 * drives them: a second initialization path would race the provider's and swallow the redirect
 * result the gate depends on.
 */
export async function acquireAccessToken(
  instance: IPublicClientApplication,
  config: RuntimeConfig,
): Promise<string> {
  const scopes = [buildApiScope(config)];
  const account = instance.getActiveAccount() ?? instance.getAllAccounts()[0];

  try {
    const result = await instance.acquireTokenSilent({ scopes, account });
    return result.accessToken;
  } catch (error) {
    if (error instanceof InteractionRequiredAuthError) {
      await instance.acquireTokenRedirect({ scopes, account });
      throw new InteractiveAuthRequiredError();
    }
    throw error;
  }
}

/** Token provider for the API client. The token is never stored outside MSAL's own cache. */
export async function getAccessToken(): Promise<string> {
  const config = getRuntimeConfig();
  return acquireAccessToken(getMsalInstance(config), config);
}
