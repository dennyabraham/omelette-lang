const { test, expect } = require("@playwright/test");

// The bundle loads asynchronously (fetch + Fengari); every test waits for "Ready".
test.beforeEach(async ({ page }) => {
  await page.goto("/play.html");
  await expect(page.locator("#output")).toContainText("Ready", { timeout: 20000 });
});

async function editAndClick(page, src, button) {
  await page.fill("#editor textarea", src);
  await page.click(button);
}

test("Run: a Shape area program prints 27", async ({ page }) => {
  await editAndClick(page,
    "type Shape = | Circle { radius } | Origin\n" +
    "let area s = match s with | Circle { radius } -> 3 * radius * radius | Origin -> 0\n" +
    "print(area(Circle { radius = 3 }))",
    "#run");
  await expect(page.locator("#output")).toContainText("27");
});

test("the editor highlights (a token span is present)", async ({ page }) => {
  await expect(page.locator("#editor .token").first()).toBeVisible({ timeout: 20000 });
});

test("Compiled Lua: shows real generated Lua", async ({ page }) => {
  await page.click("#lua");
  await expect(page.locator("#output")).toContainText("local M");
});

test("Check: a clean program reports no type errors", async ({ page }) => {
  await page.click("#check");
  await expect(page.locator("#output")).toContainText("No type errors");
});

test("Check: a type mismatch is reported", async ({ page }) => {
  await editAndClick(page, 'let x: number = "hi"', "#check");
  await expect(page.locator("#output")).toContainText("number");
});

test("Check: a non-exhaustive match is reported", async ({ page }) => {
  await editAndClick(page,
    "type T = | A { v } | B\nlet f t = match t with | A { v } -> v", "#check");
  await expect(page.locator("#output")).toContainText("missing");
});

test("Run: a runtime error is caught gracefully", async ({ page }) => {
  await editAndClick(page, "print(nope + 1)", "#run");
  await expect(page.locator("#output")).toContainText("[error]");
});

test("Run: the embedded stdlib resolves (sum -> 10)", async ({ page }) => {
  await editAndClick(page,
    'let l = require("std.list")\nprint(l.sum([1, 2, 3, 4]))', "#run");
  await expect(page.locator("#output")).toContainText("10");
});
