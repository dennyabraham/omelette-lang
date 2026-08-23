const { test, expect } = require("@playwright/test");

test("landing page loads with nav links", async ({ page }) => {
  await page.goto("/index.html");
  await expect(page.locator("h1")).toContainText("Omelette");
  await expect(page.locator('a[href="guide.html"]').first()).toBeVisible();
  await expect(page.locator('a[href="play.html"]').first()).toBeVisible();
});

test("tufte styling is applied", async ({ page }) => {
  await page.goto("/index.html");
  const family = await page.evaluate(() => getComputedStyle(document.body).fontFamily);
  expect(family.toLowerCase()).toContain("et-book");
});

test("guide renders from docs/guide.md via marked", async ({ page }) => {
  await page.goto("/guide.html");
  // marked turns the markdown into headings; wait for one inside #guide
  await expect(page.locator("#guide h1, #guide h2").first()).toBeVisible({ timeout: 20000 });
  // the loading placeholder is gone, real markup is present
  await expect(page.locator("#guide")).not.toContainText("Loading the guide");
});
