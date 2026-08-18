import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";

import { AppShell } from "../app/AppShell";
import { CostDashboard } from "../features/dashboard/CostDashboard";
import { CostDataContext } from "../features/dashboard/useCostData";
import "../styles/tokens.css";
import { PREVIEW_FILTER, previewGateway } from "./fixtures";

// preview.html is not a Rollup input, so this module can only ever be reached through the dev
// server. The guard makes that contract fail loudly instead of silently shipping fixtures.
if (!import.meta.env.DEV) {
  throw new Error("The cost dashboard preview is a development-only entry point.");
}

const container = document.getElementById("root");
if (!container) {
  throw new Error("Root container #root was not found");
}

const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } });

createRoot(container).render(
  <StrictMode>
    <QueryClientProvider client={queryClient}>
      <CostDataContext.Provider value={previewGateway}>
        <AppShell>
          <CostDashboard subscriptionName="Contoso Workshop" initialFilter={PREVIEW_FILTER} />
        </AppShell>
      </CostDataContext.Provider>
    </QueryClientProvider>
  </StrictMode>,
);
