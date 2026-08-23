// Chromium-only; serves the lua-built site/dist over http (playground needs http, not file://).
const { defineConfig, devices } = require("@playwright/test");

module.exports = defineConfig({
  testDir: ".",
  timeout: 30000,
  retries: 1,                       // guard browser-startup flake without hiding real failures
  reporter: [["html", { open: "never" }], ["list"]],
  use: { baseURL: "http://localhost:8137", trace: "on-first-retry" },
  projects: [{ name: "chromium", use: { ...devices["Desktop Chrome"] } }],
  webServer: {
    // site/dist is built by the CI lua step before playwright runs
    command: "python3 -m http.server 8137 --directory ../../site/dist",
    url: "http://localhost:8137/index.html",
    reuseExistingServer: true,
    timeout: 30000,
  },
});
