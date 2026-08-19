/**
 * The web app is browser-only, so `@types/node` is not a dependency of the frontend workspace
 * and adding it would change the production lockfile for a test-only import. The two Node
 * surfaces these specs touch are declared here instead, narrowed to what is actually called.
 */

declare module "node:child_process" {
  export interface ExecFileOptions {
    encoding: "utf8";
    maxBuffer?: number;
    windowsHide?: boolean;
    shell?: boolean;
    timeout?: number;
  }

  export function execFile(
    file: string,
    args: readonly string[],
    options: ExecFileOptions,
    callback: (error: Error | null, stdout: string, stderr: string) => void,
  ): unknown;
}

declare const process: {
  readonly env: Readonly<Record<string, string | undefined>>;
  readonly platform: string;
};
