import { EventType, InteractionStatus, InteractionType } from "@azure/msal-browser";
import type { EventMessage } from "@azure/msal-browser";
import { act, cleanup, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { StrictMode, type ReactNode } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { AuthGate } from "./AuthGate";

// vi.hoisted runs before the imports, so InteractionStatus is assigned in beforeEach instead.
const mocks = vi.hoisted(() => ({
  loginRedirect: vi.fn(() => Promise.resolve()),
  addEventCallback: vi.fn(),
  removeEventCallback: vi.fn(),
  inProgress: "none" as string,
  isAuthenticated: false,
  listeners: [] as ((message: EventMessage) => void)[],
}));

vi.mock("@azure/msal-react", () => ({
  MsalProvider: ({ children }: { children: ReactNode }) => children,
  useMsal: () => ({
    instance: {
      loginRedirect: mocks.loginRedirect,
      addEventCallback: mocks.addEventCallback,
      removeEventCallback: mocks.removeEventCallback,
    },
    inProgress: mocks.inProgress,
  }),
  useIsAuthenticated: () => mocks.isAuthenticated,
}));

const scopes = ["api://api-client-id/Cost.Read"];
const instance = {} as never;

function anEvent(eventType: string, interactionType: InteractionType): EventMessage {
  return {
    eventType,
    interactionType,
    payload: null,
    error: new Error("AADSTS50105: the user is not assigned to a role"),
    correlationId: "correlation",
    timestamp: 0,
  } as EventMessage;
}

function emit(message: EventMessage): void {
  act(() => {
    for (const listener of mocks.listeners) {
      listener(message);
    }
  });
}

function renderGate(wrapInStrictMode = false) {
  const tree = (
    <AuthGate instance={instance} scopes={scopes}>
      <p>dashboard</p>
    </AuthGate>
  );
  return render(wrapInStrictMode ? <StrictMode>{tree}</StrictMode> : tree);
}

beforeEach(() => {
  mocks.listeners = [];
  mocks.loginRedirect.mockClear();
  mocks.loginRedirect.mockResolvedValue(undefined);
  mocks.removeEventCallback.mockClear();
  mocks.addEventCallback.mockReset();
  mocks.addEventCallback.mockImplementation((...args: unknown[]) => {
    mocks.listeners.push(args[0] as (message: EventMessage) => void);
    return "callback-id";
  });
  mocks.inProgress = InteractionStatus.None;
  mocks.isAuthenticated = false;
  window.sessionStorage.clear();
});

afterEach(() => {
  cleanup();
  window.sessionStorage.clear();
});

describe("AuthGate", () => {
  it("renders children once the user is signed in", () => {
    mocks.isAuthenticated = true;

    renderGate();

    expect(screen.getByText("dashboard")).toBeInTheDocument();
    expect(mocks.loginRedirect).not.toHaveBeenCalled();
  });

  it("starts exactly one sign-in redirect and hides children when unauthenticated", () => {
    renderGate();

    expect(screen.queryByText("dashboard")).not.toBeInTheDocument();
    expect(mocks.loginRedirect).toHaveBeenCalledWith({ scopes });
    expect(mocks.loginRedirect).toHaveBeenCalledTimes(1);
  });

  it("waits for an in-flight interaction instead of redirecting again", () => {
    mocks.inProgress = InteractionStatus.HandleRedirect;

    renderGate();

    expect(mocks.loginRedirect).not.toHaveBeenCalled();
  });

  it("waits while MSAL is still starting up", () => {
    mocks.inProgress = InteractionStatus.Startup;

    renderGate();

    expect(mocks.loginRedirect).not.toHaveBeenCalled();
    expect(screen.getByRole("status")).toBeInTheDocument();
  });

  it("redirects once under StrictMode's double-invoked effects", () => {
    renderGate(true);

    expect(mocks.loginRedirect).toHaveBeenCalledTimes(1);
  });

  it("surfaces a failure when the redirect cannot start", async () => {
    mocks.loginRedirect.mockRejectedValue(new Error("popup blocked"));

    renderGate();

    expect(await screen.findByRole("alert")).toHaveTextContent(/sign-in failed/i);
  });

  it("renders an alert instead of looping when Entra returns a sign-in error", () => {
    renderGate();
    expect(mocks.loginRedirect).toHaveBeenCalledTimes(1);

    emit(anEvent(EventType.ACQUIRE_TOKEN_FAILURE, InteractionType.Redirect));

    expect(screen.getByRole("alert")).toHaveTextContent(/sign-in failed/i);
    expect(mocks.loginRedirect).toHaveBeenCalledTimes(1);
  });

  it("never quotes the Entra error text in the alert", () => {
    renderGate();

    emit(anEvent(EventType.ACQUIRE_TOKEN_FAILURE, InteractionType.Redirect));

    expect(screen.getByRole("alert").textContent).not.toContain("AADSTS50105");
  });

  it("ignores a silent token failure, which the API client handles on its own", () => {
    renderGate();

    emit(anEvent(EventType.ACQUIRE_TOKEN_FAILURE, InteractionType.Silent));

    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
    expect(screen.getByRole("status")).toBeInTheDocument();
  });

  it("stops after one round trip when the redirect returns without an account", () => {
    renderGate();
    expect(mocks.loginRedirect).toHaveBeenCalledTimes(1);

    // The redirect came back, MsalProvider swallowed the rejection, and the page remounted
    // still unauthenticated. Without the attempt marker this is where the loop starts.
    cleanup();
    mocks.loginRedirect.mockClear();
    renderGate();

    expect(screen.getByRole("alert")).toHaveTextContent(/sign-in failed/i);
    expect(mocks.loginRedirect).not.toHaveBeenCalled();
  });

  it("offers a manual retry that starts a new redirect", async () => {
    mocks.loginRedirect.mockRejectedValue(new Error("popup blocked"));
    renderGate();
    await screen.findByRole("alert");
    mocks.loginRedirect.mockResolvedValue(undefined);
    mocks.loginRedirect.mockClear();

    await userEvent.click(screen.getByRole("button", { name: /try signing in again/i }));

    expect(mocks.loginRedirect).toHaveBeenCalledWith({ scopes });
    expect(mocks.loginRedirect).toHaveBeenCalledTimes(1);
  });

  it("clears the attempt marker once the user is signed in", () => {
    renderGate();
    cleanup();
    mocks.isAuthenticated = true;
    mocks.loginRedirect.mockClear();

    renderGate();

    expect(screen.getByText("dashboard")).toBeInTheDocument();

    // A later sign-out must be able to redirect again rather than land on the alert.
    cleanup();
    mocks.isAuthenticated = false;
    renderGate();

    expect(mocks.loginRedirect).toHaveBeenCalledTimes(1);
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
  });

  it("unsubscribes its event callback on unmount", () => {
    renderGate();

    cleanup();

    expect(mocks.removeEventCallback).toHaveBeenCalledWith("callback-id");
  });

  it("survives a sessionStorage that refuses to answer", () => {
    const getItem = vi.spyOn(Storage.prototype, "getItem").mockImplementation(() => {
      throw new Error("storage disabled");
    });
    const setItem = vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
      throw new Error("storage disabled");
    });

    try {
      renderGate();

      expect(mocks.loginRedirect).toHaveBeenCalledTimes(1);
    } finally {
      getItem.mockRestore();
      setItem.mockRestore();
    }
  });
});
