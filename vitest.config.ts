import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    environment: "node",
    include: ["tests/**/*.test.{mjs,ts,tsx}"],
    // Ink render tests share terminal globals — run serially (nanocoder uses AVA serial too).
    fileParallelism: false,
    pool: "forks",
    globalSetup: ["tests/setup/global-setup.mjs"],
  },
});
