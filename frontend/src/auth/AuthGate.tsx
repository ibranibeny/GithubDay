import {
  EventType,
  InteractionStatus,
  InteractionType,
  type EventMessage,
  type IPublicClientApplication,
} from "@azure/msal-browser";
import { MsalProvider, useIsAuthenticated, useMsal } from "@azure/msal-react";
import { useCallback, useEffect, useRef, useState, type ReactNode } from "react";

export interface AuthGateProps {
  instance: IPublicClientApplication;
  scopes: string[];
  children: ReactNode;
}

/**
 * MsalProvider performs initialize() and handleRedirectPromise() itself, so the gate only has to
 * drive sign-in and withhold children until an account exists.
 */
export function AuthGate({ instance, scopes, children }: AuthGateProps) {
  return (
    <MsalProvider instance={instance}>
      <SignInGate scopes={scopes}>{children}</SignInGate>
    </MsalProvider>
  );
}

// Survives the sign-in redirect, which a ref cannot: the page is reloaded in between.
const ATTEMPT_KEY = "cost-copilot.sign-in-attempted";

function attemptMade(): boolean {
  try {
    return window.sessionStorage.getItem(ATTEMPT_KEY) !== null;
  } catch {
    // A blocked sessionStorage costs the loop guard, not the sign-in.
    return false;
  }
}

function recordAttempt(): void {
  try {
    window.sessionStorage.setItem(ATTEMPT_KEY, "1");
  } catch {
    // As above: best effort.
  }
}

function forgetAttempt(): void {
  try {
    window.sessionStorage.removeItem(ATTEMPT_KEY);
  } catch {
    // As above: best effort.
  }
}

function SignInGate({ scopes, children }: { scopes: string[]; children: ReactNode }) {
  const { instance, inProgress } = useMsal();
  const isAuthenticated = useIsAuthenticated();
  const [signInRejected, setSignInRejected] = useState(false);
  // Read once per page load, not per render: the marker describes the redirect this load
  // came back from, and startSignIn writes a new one for the *next* load.
  const [cameBackEmptyHanded, setCameBackEmptyHanded] = useState(attemptMade);
  // StrictMode invokes effects twice on the same fiber, which keeps refs but would call
  // loginRedirect twice and make MSAL raise interaction_in_progress.
  const redirecting = useRef(false);

  const settled = inProgress === InteractionStatus.None;
  // MsalProvider swallows the handleRedirectPromise rejection, so a returned Entra error --
  // an unassigned user, a denied consent -- leaves no exception to catch. Coming back from a
  // recorded attempt with no account, once MSAL has settled, is the only remaining signal.
  const failed = signInRejected || (cameBackEmptyHanded && settled && !isAuthenticated);

  const startSignIn = useCallback(() => {
    redirecting.current = true;
    setSignInRejected(false);
    setCameBackEmptyHanded(false);
    recordAttempt();
    void instance.loginRedirect({ scopes }).catch(() => {
      redirecting.current = false;
      forgetAttempt();
      setSignInRejected(true);
    });
  }, [instance, scopes]);

  useEffect(() => {
    // The faster of the two failure signals, and the only one for a failure MSAL reports
    // without ending the interaction. Silent failures are excluded: the API client answers
    // those with its own token redirect.
    const callbackId = instance.addEventCallback(
      (message: EventMessage) => {
        if (
          message.eventType === EventType.ACQUIRE_TOKEN_FAILURE &&
          message.interactionType === InteractionType.Redirect
        ) {
          redirecting.current = false;
          forgetAttempt();
          setSignInRejected(true);
        }
      },
      [EventType.ACQUIRE_TOKEN_FAILURE],
    );

    return () => {
      if (callbackId) {
        instance.removeEventCallback(callbackId);
      }
    };
  }, [instance]);

  useEffect(() => {
    if (isAuthenticated) {
      forgetAttempt();
      return;
    }
    if (failed || redirecting.current || !settled) {
      return;
    }
    startSignIn();
  }, [failed, isAuthenticated, settled, startSignIn]);

  if (failed) {
    // The Entra error text is never rendered: it names the tenant and the policy that refused.
    return (
      <div role="alert">
        <p>Sign-in failed. Your account may not have access to Azure Cost Copilot.</p>
        <button type="button" onClick={startSignIn}>
          Try signing in again
        </button>
      </div>
    );
  }
  if (!isAuthenticated) {
    return <p role="status">Signing in…</p>;
  }
  return <>{children}</>;
}
