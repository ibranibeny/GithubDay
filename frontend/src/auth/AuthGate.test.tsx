import { InteractionStatus } from "@azure/msal-browser";
import { cleanup, render, screen } from "@testing-library/react";
import type { ReactNode } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { AuthGate } from "./AuthGate";

// vi.hoisted runs before the imports, so InteractionStatus is assigned in beforeEach instead.
const mocks = vi.hoisted(() => ({
  loginRedirect: vi.fn(() => Promise.resolve()),
  inProgress: "none" as string,
  isAuthenticated: false,
}));

vi.mock("@azure/msal-react", () => ({
  MsalProvider: ({ children }: { children: ReactNode }) => children,
  useMsal: () => ({
    instance: { loginRedirect: mocks.loginRedirect },
    inProgress: mocks.inProgress,
  }),
  useIsAuthenticated: () => mocks.isAuthenticated,
}));

const scopes = ["api://api-client-id/Cost.Read"];
const instance = {} as never;

beforeEach(() => {
  mocks.loginRedirect.mockClear();
  mocks.loginRedirect.mockResolvedValue(undefined);
  mocks.inProgress = InteractionStatus.None;
  mocks.isAuthenticated = false;
});

afterEach(() => {
  cleanup();
});

describe("AuthGate", () => {
  it("renders children once the user is signed in", () => {
    mocks.isAuthenticated = true;

    render(
      <AuthGate instance={instance} scopes={scopes}>
        <p>dashboard</p>
      </AuthGate>,
    );

    expect(screen.getByText("dashboard")).toBeInTheDocument();
    expect(mocks.loginRedirect).not.toHaveBeenCalled();
  });

  it("starts a sign-in redirect and hides children when unauthenticated", () => {
    render(
      <AuthGate instance={instance} scopes={scopes}>
        <p>dashboard</p>
      </AuthGate>,
    );

    expect(screen.queryByText("dashboard")).not.toBeInTheDocument();
    expect(mocks.loginRedirect).toHaveBeenCalledWith({ scopes });
  });

  it("waits for an in-flight interaction instead of redirecting again", () => {
    mocks.inProgress = InteractionStatus.HandleRedirect;

    render(
      <AuthGate instance={instance} scopes={scopes}>
        <p>dashboard</p>
      </AuthGate>,
    );

    expect(mocks.loginRedirect).not.toHaveBeenCalled();
  });

  it("surfaces a failure when the redirect cannot start", async () => {
    mocks.loginRedirect.mockRejectedValue(new Error("popup blocked"));

    render(
      <AuthGate instance={instance} scopes={scopes}>
        <p>dashboard</p>
      </AuthGate>,
    );

    expect(await screen.findByRole("alert")).toHaveTextContent(/sign-in failed/i);
  });
});
