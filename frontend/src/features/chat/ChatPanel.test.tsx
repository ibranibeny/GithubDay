import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { cleanup, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";

import type { ChatResponse, CostFilter, Evidence } from "../../api/contracts";
import { ChatPanel } from "./ChatPanel";
import { ChatGatewayContext, type ChatGateway } from "./useCostChat";

const FILTER: CostFilter = {
  from: "2026-08-01",
  to: "2026-08-31",
  metric: "ActualCost",
  grouping: "ServiceName",
};

const EVIDENCE: Evidence = {
  metric: "AmortizedCost",
  dimension: "Azure App Service",
  periodStart: "2026-07-01",
  periodEnd: "2026-07-31",
  amount: 1620.4,
};

const PROMPT_LABEL = "Ask about these costs";

function reply(overrides: Partial<ChatResponse> = {}): ChatResponse {
  return {
    answer: "App Service is the largest driver in this period.",
    evidence: [EVIDENCE],
    chartActions: [],
    explanationAvailable: true,
    ...overrides,
  };
}

function renderPanel(response: ChatResponse, filter: CostFilter | null = FILTER) {
  const send = vi.fn(() => Promise.resolve(response));
  const gateway: ChatGateway = { send };
  const onApplyEvidence = vi.fn();
  const onApplyAction = vi.fn();
  const client = new QueryClient({
    defaultOptions: { mutations: { retry: false }, queries: { retry: false } },
  });

  render(
    <QueryClientProvider client={client}>
      <ChatGatewayContext.Provider value={gateway}>
        <ChatPanel
          filter={filter}
          currency="USD"
          onApplyEvidence={onApplyEvidence}
          onApplyAction={onApplyAction}
        />
      </ChatGatewayContext.Provider>
    </QueryClientProvider>,
  );

  return { send, onApplyEvidence, onApplyAction };
}

async function ask(user: ReturnType<typeof userEvent.setup>, prompt = "Why did cost rise?") {
  await user.type(screen.getByLabelText(PROMPT_LABEL), prompt);
  await user.click(screen.getByRole("button", { name: "Send" }));
}

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

describe("ChatPanel", () => {
  it("applies the metric and the period of the evidence the reader selects", async () => {
    const user = userEvent.setup();
    const { onApplyEvidence } = renderPanel(reply());

    await ask(user);

    const link = await screen.findByRole("button", {
      name: "Apply Amortized cost for Azure App Service, 2026-07-01 to 2026-07-31",
    });
    await user.click(link);

    expect(onApplyEvidence).toHaveBeenCalledTimes(1);
    expect(onApplyEvidence).toHaveBeenCalledWith(
      expect.objectContaining({
        metric: "AmortizedCost",
        periodStart: "2026-07-01",
        periodEnd: "2026-07-31",
      }),
    );
  });

  it("blocks sending an empty prompt", async () => {
    const user = userEvent.setup();
    const { send } = renderPanel(reply());

    const button = screen.getByRole("button", { name: "Send" });
    expect(button).toBeDisabled();

    await user.type(screen.getByLabelText(PROMPT_LABEL), "   ");
    expect(button).toBeDisabled();

    await user.click(button);
    expect(send).not.toHaveBeenCalled();
  });

  it("blocks sending while no cost filter is active", async () => {
    const user = userEvent.setup();
    const { send } = renderPanel(reply(), null);

    await user.type(screen.getByLabelText(PROMPT_LABEL), "Why did cost rise?");
    const button = screen.getByRole("button", { name: "Send" });
    expect(button).toBeDisabled();

    await user.click(button);
    expect(send).not.toHaveBeenCalled();
  });

  it("renders the assistant answer as text so markup in it cannot execute", async () => {
    const user = userEvent.setup();
    const injected = '<img src=x onerror="alert(1)">App Service grew.';
    renderPanel(reply({ answer: injected }));

    await ask(user, '<img src=x onerror="alert(1)">');

    const log = await screen.findByRole("log");
    await waitFor(() => {
      expect(log).toHaveTextContent(injected);
    });
    expect(log.querySelector("img")).toBeNull();
    expect(document.querySelectorAll("img")).toHaveLength(0);
  });

  it("keeps the cost evidence when the explanation is unavailable", async () => {
    const user = userEvent.setup();
    renderPanel(reply({ answer: "", explanationAvailable: false }));

    await ask(user);

    expect(
      await screen.findByRole("button", {
        name: "Apply Amortized cost for Azure App Service, 2026-07-01 to 2026-07-31",
      }),
    ).toBeInTheDocument();
    expect(screen.getByText("$1,620.40")).toBeInTheDocument();
    expect(
      screen.getByText(
        "The written explanation is unavailable. The figures below still come from the cost data.",
      ),
    ).toBeInTheDocument();
  });

  it("ignores a chart action with an unknown kind or an invalid dimension", async () => {
    const user = userEvent.setup();
    const { onApplyAction } = renderPanel(
      reply({
        chartActions: [
          { kind: "delete-everything", value: "Azure App Service" },
          { kind: "set-filter", metric: "MadeUpCost" },
          { kind: "highlight-series", grouping: "NotADimension", value: "x" },
          { kind: "highlight-series", grouping: "ServiceName", value: "Azure App Service" },
        ] as ChatResponse["chartActions"],
      }),
    );

    await ask(user);

    const actions = await screen.findByRole("group", { name: "Chart actions" });
    const buttons = await waitFor(() => {
      const found = actions.querySelectorAll("button");
      expect(found).toHaveLength(1);
      return found;
    });

    await user.click(buttons[0]);
    expect(onApplyAction).toHaveBeenCalledTimes(1);
    expect(onApplyAction).toHaveBeenCalledWith({
      kind: "highlight-series",
      grouping: "ServiceName",
      value: "Azure App Service",
    });
  });
});
