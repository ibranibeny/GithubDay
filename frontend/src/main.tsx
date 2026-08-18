import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";

import { RuntimeConfigError, getRuntimeConfig } from "./app/runtime-config";
import { AuthGate } from "./auth/AuthGate";
import { buildApiScope, getMsalInstance } from "./auth/msal";

const container = document.getElementById("root");
if (!container) {
  throw new Error("Root container #root was not found");
}

const root = createRoot(container);

try {
  const config = getRuntimeConfig();
  const queryClient = new QueryClient();

  root.render(
    <StrictMode>
      <QueryClientProvider client={queryClient}>
        <AuthGate instance={getMsalInstance(config)} scopes={[buildApiScope(config)]}>
          <main>Azure Cost Copilot</main>
        </AuthGate>
      </QueryClientProvider>
    </StrictMode>,
  );
} catch (error) {
  // Only RuntimeConfigError text is shown; it names fields, never their values.
  const detail = error instanceof RuntimeConfigError ? ` ${error.message}.` : "";
  root.render(
    <StrictMode>
      <main role="alert">Azure Cost Copilot is not configured correctly.{detail}</main>
    </StrictMode>,
  );
}
