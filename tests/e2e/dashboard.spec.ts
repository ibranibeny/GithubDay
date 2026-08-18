import { expect, test, type Locator, type Page } from "@playwright/test";

/**
 * These run against `preview.html`, the development-only fixture harness: it renders the real
 * dashboard and the real chat panel against in-memory gateways, so no Entra sign-in and no API
 * are involved and every figure asserted below is fixed. `live-api.spec.ts` covers the wire.
 */

const PREVIEW = "/preview.html";

// From frontend/src/preview/fixtures.ts: the canned grounded reply cites these two figures, and
// the donut fixtures are built from the same shares, so the numbers agree by construction.
const APP_SERVICE_AMOUNT = "$1,396.09";
const COSMOS_AMOUNT = "$1,130.85";

test.beforeEach(async ({ page }) => {
  // echarts-for-react resolves its `finished` event from a requestAnimationFrame loop, and a
  // browser pauses raf for an occluded or hidden page. On a busy runner that leaves the SVG
  // renderer with an empty <svg> and turns "the chart drew" into a timing question. Replacing
  // raf with a timer, and pinning visibility, makes rendering independent of the window state.
  await page.addInitScript(() => {
    window.requestAnimationFrame = (callback) =>
      window.setTimeout(() => callback(performance.now()), 16);
    window.cancelAnimationFrame = (handle) => window.clearTimeout(handle);
    Object.defineProperty(document, "visibilityState", {
      get: () => "visible",
      configurable: true,
    });
    Object.defineProperty(document, "hidden", { get: () => false, configurable: true });
  });
  await page.goto(PREVIEW);
});

test("draws the accumulated cost line and the breakdown donuts", async ({ page }) => {
  const trend = page.locator(".trend__slot svg");
  await expect(trend).toBeVisible();
  // A blank <svg> is the failure this guards: assert on drawn geometry, not on the element.
  await expect.poll(() => trend.locator("path, polyline").count()).toBeGreaterThan(0);

  const donut = page.locator('section.panel[data-dimension="ServiceName"] .panel__slot svg');
  await expect(donut).toBeVisible();
  await expect.poll(() => donut.locator("path").count()).toBeGreaterThan(0);
});

test("changing the grouping moves the active panel", async ({ page }) => {
  const serviceName = panel(page, "ServiceName");
  const resourceGroup = panel(page, "ResourceGroupName");

  await expect(serviceName).toHaveClass(/panel--active/);
  await expect(serviceName.locator(".panel__badge")).toHaveText("Grouping");

  await page.getByLabel("Group by", { exact: true }).selectOption("ResourceGroupName");

  await expect(resourceGroup).toHaveClass(/panel--active/);
  await expect(resourceGroup.locator(".panel__badge")).toHaveText("Grouping");
  await expect(serviceName.locator(".panel__badge")).toHaveCount(0);
  // The fixture's resource-group ranking, so the panel is showing the new dimension's data.
  await expect(resourceGroup.locator(".ranked__name").first()).toHaveText("rg-workshop-prod");
});

test("changing the metric keeps the page intact", async ({ page }) => {
  const metric = page.getByLabel("Metric", { exact: true });
  await expect(metric).toHaveValue("ActualCost");

  await metric.selectOption("AmortizedCost");

  await expect(metric).toHaveValue("AmortizedCost");
  // The metric is a query parameter, not a period: the window must survive the change.
  await expect(page.getByLabel("Period", { exact: true })).toHaveValue("2026-08");
  // No slot fell back to its error message and no access alert replaced the page.
  await expect(page.getByRole("alert")).toHaveCount(0);
  await expect.poll(() => page.locator(".trend__slot svg path").count()).toBeGreaterThan(0);
});

test.describe("desktop layout", () => {
  test.skip(({ isMobile }) => !!isMobile, "asserts the wide three-column shell");

  test("keeps the rail labelled and the KPIs on one row", async ({ page }) => {
    await expect(page.locator(".rail__label").first()).toBeVisible();

    const boxes = await boundingBoxes(page.locator(".kpi"));
    expect(boxes.length).toBeGreaterThan(1);
    for (const box of boxes.slice(1)) {
      expect(box.y).toBeCloseTo(boxes[0].y, 0);
      expect(box.x).toBeGreaterThan(boxes[0].x);
    }
  });

  test("reaches the command bar by Tab and activates a control with Enter", async ({ page }) => {
    await page.keyboard.press("Tab");
    // The navigation rail is the first focusable region, so this is the entry point of the order.
    await expect(page.locator(".rail__item").first()).toBeFocused();

    const refresh = page.getByRole("button", { name: "Refresh" });
    let reached = false;
    for (let step = 0; step < 20 && !reached; step += 1) {
      await page.keyboard.press("Tab");
      reached = await refresh.evaluate((node) => node === document.activeElement);
    }
    expect(reached, "Tab should reach the Refresh command").toBe(true);

    await expect(page.getByLabel("Tag key", { exact: true })).toHaveCount(0);
    await page.getByRole("button", { name: "Add tag filter" }).focus();
    await page.keyboard.press("Enter");
    await expect(page.getByLabel("Tag key", { exact: true })).toBeVisible();
  });
});

test.describe("mobile layout", () => {
  test.skip(({ isMobile }) => !isMobile, "asserts the narrow single-column shell");

  test("collapses the rail to icons and stacks the KPIs", async ({ page }) => {
    await expect(page.locator(".rail__label").first()).toBeHidden();

    const boxes = await boundingBoxes(page.locator(".kpi"));
    expect(boxes.length).toBeGreaterThan(1);
    for (const [index, box] of boxes.entries()) {
      if (index === 0) {
        continue;
      }
      expect(box.x).toBeCloseTo(boxes[0].x, 0);
      expect(box.y).toBeGreaterThan(boxes[index - 1].y);
    }
  });
});

test("answers with evidence and chart actions drawn from the same figures", async ({ page }) => {
  await ask(page, "Why is August over budget?");

  const evidence = page.locator(".assistant__evidence button.evidence");
  await expect(evidence).toHaveCount(2);
  await expect(evidence.nth(0)).toContainText("Azure App Service");
  await expect(evidence.nth(0)).toContainText(APP_SERVICE_AMOUNT);
  await expect(evidence.nth(1)).toContainText("Azure Cosmos DB");
  await expect(evidence.nth(1)).toContainText(COSMOS_AMOUNT);

  await expect(page.locator(".assistant__action")).toHaveCount(3);
});

test("applying a citation moves the dashboard to the window it was read from", async ({ page }) => {
  const period = page.getByLabel("Period", { exact: true });
  await period.selectOption("2026-07");
  await expect(period).toHaveValue("2026-07");

  await ask(page, "Which service costs the most?");
  await page.locator(".assistant__evidence button.evidence").first().click();

  // The citation is stamped 2026-08-01..2026-08-19, so the period control returns to August.
  await expect(period).toHaveValue("2026-08");
  await expect(page.getByLabel("Metric", { exact: true })).toHaveValue("ActualCost");
  await expect(page.locator('[data-emphasised="true"]')).toContainText("Azure App Service");
});

test("a chart action highlights and refilters the dashboard", async ({ page }) => {
  await ask(page, "Show me the biggest driver.");

  await expect(page.locator('[data-emphasised="true"]')).toHaveCount(0);
  await page.getByRole("button", { name: /^Highlight Azure App Service/ }).click();

  const emphasised = page.locator('section.panel[data-dimension="ServiceName"] [data-emphasised]');
  await expect(emphasised).toHaveCount(1);
  await expect(emphasised).toContainText("Azure App Service");

  await page.getByRole("button", { name: /^Show amortized cost$/ }).click();
  await expect(page.getByLabel("Metric", { exact: true })).toHaveValue("AmortizedCost");
});

function panel(page: Page, dimension: string): Locator {
  return page.locator(`section.panel[data-dimension="${dimension}"]`);
}

async function ask(page: Page, question: string): Promise<void> {
  await page.locator(".assistant__input").fill(question);
  // requestSubmit rather than clicking Send: it is the same submit path React listens on, and it
  // does not depend on the button being unobscured in whichever viewport the project uses.
  await page
    .locator("form.assistant__compose")
    .evaluate((form) => (form as HTMLFormElement).requestSubmit());
  await expect(page.locator(".assistant__evidence")).toBeVisible();
}

async function boundingBoxes(locator: Locator): Promise<{ x: number; y: number }[]> {
  const elements = await locator.all();
  const boxes: { x: number; y: number }[] = [];
  for (const element of elements) {
    const box = await element.boundingBox();
    expect(box, "every KPI card should be laid out").not.toBeNull();
    boxes.push({ x: box?.x ?? 0, y: box?.y ?? 0 });
  }
  return boxes;
}
