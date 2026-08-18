import { InteractionStatus, type IPublicClientApplication } from "@azure/msal-browser";
import { MsalProvider, useIsAuthenticated, useMsal } from "@azure/msal-react";
import { useEffect, useState, type ReactNode } from "react";

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

function SignInGate({ scopes, children }: { scopes: string[]; children: ReactNode }) {
  const { instance, inProgress } = useMsal();
  const isAuthenticated = useIsAuthenticated();
  const [redirectFailed, setRedirectFailed] = useState(false);

  useEffect(() => {
    if (isAuthenticated || inProgress !== InteractionStatus.None) {
      return;
    }
    void instance.loginRedirect({ scopes }).catch(() => setRedirectFailed(true));
  }, [instance, inProgress, isAuthenticated, scopes]);

  if (redirectFailed) {
    return <p role="alert">Sign-in failed. Reload the page to try again.</p>;
  }
  if (!isAuthenticated) {
    return <p role="status">Signing in…</p>;
  }
  return <>{children}</>;
}
