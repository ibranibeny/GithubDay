import { StrictMode } from "react";
import { createRoot } from "react-dom/client";

const container = document.getElementById("root");
if (!container) {
  throw new Error("Root container #root was not found");
}

createRoot(container).render(
  <StrictMode>
    <main>Azure Cost Copilot</main>
  </StrictMode>,
);
