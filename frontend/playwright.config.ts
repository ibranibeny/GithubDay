import { defineConfig, devices } from "@playwright/test";

// A port of its own so a developer's `npm run dev` on 5173 is never adopted as the fixture
// server, and --strictPort makes a clash fail loudly instead of silently moving the suite.
const PORT = 5199;
const BASE_URL = `http://localhost:${PORT}`;

/**
 * The specs live at the repository root (`tests/e2e`) because `live-api.spec.ts` tests the
 * deployed API rather than this package; only the browser projects need the web app. Module
 * specifiers in those specs resolve through `tests/e2e/tsconfig.json` `paths`, which Playwright
 * honours, so they can import `@playwright/test` from this package's `node_modules`.
 *
 * Browsers are never installed on a developer machine by this repository: the suite is a CI
 * gate. Run `npx playwright install --with-deps chromium` on the runner before `npm run test:e2e`.
 */
export default defineConfig({
  testDir: "../tests/e2e",
  outputDir: "./test-results",
  timeout: 45_000,
  expect: { timeout: 10_000 },
  fullyParallel: true,
  // A committed `.only` silently shrinks the gate to one test, so CI refuses the run outright.
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  // One worker in CI: the shared dev server and the staging API are the bottleneck, not the CPU.
  workers: process.env.CI ? 1 : undefined,
  reporter: process.env.CI
    ? [["github"], ["html", { open: "never" }], ["list"]]
    : [["list"], ["html", { open: "never" }]],
  use: {
    baseURL: BASE_URL,
    trace: "on-first-retry",
    screenshot: "only-on-failure",
    video: "off",
  },
  projects: [
    {
      name: "desktop-chromium",
      use: { ...devices["Desktop Chrome"], viewport: { width: 1440, height: 900 } },
    },
    {
      // Pixel 5 carries the mobile user agent, touch, and device scale factor; the viewport is
      // pinned so the assertions describe a fixed width rather than whatever the device preset
      // happens to be in the installed Playwright version.
      name: "mobile-chromium",
      use: { ...devices["Pixel 5"], viewport: { width: 390, height: 844 } },
    },
  ],
  webServer: {
    // Invoked through node, not npm: the runner may have a package manager that is not npm, and
    // an npm script adds a shell layer that swallows the dev server's exit code.
    command: `node ./node_modules/vite/bin/vite.js --port ${PORT} --strictPort`,
    // preview.html rather than /: it is the fixture harness the dashboard specs drive, and it
    // renders without Entra or an API, so readiness here means the specs can actually start.
    url: `${BASE_URL}/preview.html`,
    reuseExistingServer: !process.env.CI,
    timeout: 120_000,
    stdout: "ignore",
    stderr: "pipe",
  },
});
