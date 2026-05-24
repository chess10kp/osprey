import { describe, expect, it } from "vitest";
import {
  DEFAULT_AUTO_COMPACT,
  resolveAutoCompactConfig,
  shouldAutoCompact,
} from "../../src/session/auto-compact.js";
import type { ContextUsage } from "../../src/workflow/context-usage.js";

describe("resolveAutoCompactConfig", () => {
  it("defaults to LLM strategy", () => {
    const cfg = resolveAutoCompactConfig({});
    expect(cfg.strategy).toBe("llm");
    expect(cfg.enabled).toBe(true);
    expect(cfg.thresholdPercent).toBe(DEFAULT_AUTO_COMPACT.thresholdPercent);
  });

  it("honors compactStrategy top-level override", () => {
    const cfg = resolveAutoCompactConfig({ compactStrategy: "mechanical" });
    expect(cfg.strategy).toBe("mechanical");
  });

  it("disables when autoCompact is false", () => {
    const cfg = resolveAutoCompactConfig({ autoCompact: false });
    expect(cfg.enabled).toBe(false);
  });
});

describe("shouldAutoCompact", () => {
  const usage: ContextUsage = {
    used: 900,
    max: 1000,
    percent: 90,
    systemTokens: 100,
    messageTokens: 800,
    available: 100,
  };

  it("triggers at threshold", () => {
    expect(shouldAutoCompact(usage, { ...DEFAULT_AUTO_COMPACT, thresholdPercent: 80 })).toBe(true);
    expect(shouldAutoCompact(usage, { ...DEFAULT_AUTO_COMPACT, enabled: false })).toBe(false);
    expect(
      shouldAutoCompact(
        { ...usage, percent: 50 },
        { ...DEFAULT_AUTO_COMPACT, thresholdPercent: 80 },
      ),
    ).toBe(false);
  });
});
