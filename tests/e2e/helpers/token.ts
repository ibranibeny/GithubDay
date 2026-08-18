import { execFile } from "node:child_process";

const AZ_TIMEOUT_MS = 60_000;
const MAX_OUTPUT_BYTES = 4 * 1024 * 1024;
const MAX_ERROR_CHARS = 500;

/**
 * `az` is invoked through a shell on Windows because the installed entry point is `az.cmd`.
 * A shell turns the resource into a parseable string, so it is checked against the character
 * set an Entra application ID URI can legally contain before it is ever passed along.
 */
const SAFE_RESOURCE = /^[A-Za-z0-9:/._-]+$/;

/**
 * Exchanges the ambient Azure CLI login for an access token for `resource`.
 *
 * In CI the ambient login is the GitHub OIDC federated identity, so no secret is involved and
 * nothing has to be written to disk. The token is returned to the caller and never logged,
 * echoed into an assertion message, or attached to a Playwright trace.
 */
export function getAccessToken(resource: string): Promise<string> {
  if (!SAFE_RESOURCE.test(resource)) {
    return Promise.reject(new Error("Refusing to request a token for a malformed resource id"));
  }

  return new Promise<string>((resolve, reject) => {
    execFile(
      "az",
      [
        "account",
        "get-access-token",
        "--resource",
        resource,
        "--query",
        "accessToken",
        "-o",
        "tsv",
      ],
      {
        encoding: "utf8",
        maxBuffer: MAX_OUTPUT_BYTES,
        windowsHide: true,
        timeout: AZ_TIMEOUT_MS,
        shell: process.platform === "win32",
      },
      (error, stdout, stderr) => {
        if (error) {
          // az writes diagnostics to stderr and the token to stdout, so only stderr is quoted.
          reject(new Error(`az account get-access-token failed: ${clip(stderr)}`));
          return;
        }
        // The Windows build of az terminates lines with CRLF, which an Authorization header
        // cannot carry; trimming is what makes the value usable, not cosmetic.
        const token = stdout.trim();
        if (!token) {
          reject(new Error("az account get-access-token returned an empty token"));
          return;
        }
        resolve(token);
      },
    );
  });
}

function clip(text: string): string {
  const single = text.trim().replace(/\s+/g, " ");
  return single.length > MAX_ERROR_CHARS ? `${single.slice(0, MAX_ERROR_CHARS)}…` : single;
}
