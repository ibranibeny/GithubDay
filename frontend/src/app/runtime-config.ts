import { z } from "zod";

declare global {
  interface Window {
    __APP_CONFIG__?: unknown;
  }
}

export interface RuntimeConfig {
  tenantId: string;
  spaClientId: string;
  apiClientId: string;
  apiBaseUrl: string;
  environment?: string;
  appInsightsConnectionString?: string;
}

export class RuntimeConfigError extends Error {
  readonly fields: string[];

  constructor(fields: string[]) {
    super(`Runtime configuration is missing or invalid: ${fields.join(", ")}`);
    this.name = "RuntimeConfigError";
    this.fields = fields;
  }
}

// envsubst leaves "${VAR}" untouched when the variable is unset, so a literal placeholder
// reaching the browser means the container was started without its configuration.
const PLACEHOLDER = /^\$\{[^}]*\}$/;

const requiredValue = z
  .string()
  .trim()
  .min(1)
  .refine((value) => !PLACEHOLDER.test(value), { message: "unsubstituted placeholder" });

const optionalValue = z.string().trim().optional();

const absoluteHttpUrl = requiredValue.refine(
  (value) => {
    try {
      const { protocol } = new URL(value);
      return protocol === "http:" || protocol === "https:";
    } catch {
      return false;
    }
  },
  { message: "must be an absolute http(s) URL" },
);

const runtimeConfigSchema = z.object({
  tenantId: requiredValue,
  spaClientId: requiredValue,
  apiClientId: requiredValue,
  apiBaseUrl: absoluteHttpUrl,
  environment: optionalValue,
  appInsightsConnectionString: optionalValue,
});

function normalizeOptional(value: string | undefined): string | undefined {
  if (!value || PLACEHOLDER.test(value)) {
    return undefined;
  }
  return value;
}

export function parseRuntimeConfig(raw: unknown): RuntimeConfig {
  if (typeof raw !== "object" || raw === null) {
    throw new RuntimeConfigError(["window.__APP_CONFIG__"]);
  }

  const result = runtimeConfigSchema.safeParse(raw);
  if (!result.success) {
    const fields = [...new Set(result.error.issues.map((issue) => issue.path.join(".")))];
    throw new RuntimeConfigError(fields);
  }

  return {
    tenantId: result.data.tenantId,
    spaClientId: result.data.spaClientId,
    apiClientId: result.data.apiClientId,
    apiBaseUrl: result.data.apiBaseUrl,
    environment: normalizeOptional(result.data.environment),
    appInsightsConnectionString: normalizeOptional(result.data.appInsightsConnectionString),
  };
}

export function getRuntimeConfig(): RuntimeConfig {
  return parseRuntimeConfig(window.__APP_CONFIG__);
}
