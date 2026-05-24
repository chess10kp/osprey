import { describe, expect, it } from "vitest";
import {
  cycleMode,
  isDestructiveBash,
  isToolAllowedInPlanMode,
  parseModeFlag,
  shouldAutoApprove,
} from "../../src/runtime/dev-mode.js";

describe("isDestructiveBash", () => {
  it("flags rm -rf /", () => {
    expect(isDestructiveBash("rm -rf /")).toBe(true);
  });

  it("flags git push --force", () => {
    expect(isDestructiveBash("git push --force origin main")).toBe(true);
  });

  it("flags git reset --hard", () => {
    expect(isDestructiveBash("git reset --hard HEAD~1")).toBe(true);
  });

  it("allows benign commands", () => {
    expect(isDestructiveBash("ls -la")).toBe(false);
    expect(isDestructiveBash("git status")).toBe(false);
    expect(isDestructiveBash("npm test")).toBe(false);
  });

  it("returns false for empty command", () => {
    expect(isDestructiveBash("   ")).toBe(false);
  });
});

describe("shouldAutoApprove", () => {
  it("never auto-approves in normal mode", () => {
    expect(shouldAutoApprove("normal", "read", {})).toBe(false);
  });

  it("auto-approves all tools in yolo mode", () => {
    expect(shouldAutoApprove("yolo", "bash", { command: "rm -rf /" })).toBe(true);
  });

  it("auto-approves safe bash in auto-accept mode", () => {
    expect(shouldAutoApprove("auto-accept", "bash", { command: "npm test" })).toBe(true);
  });

  it("blocks destructive bash in auto-accept mode", () => {
    expect(
      shouldAutoApprove("auto-accept", "bash", { command: "git push --force" }),
    ).toBe(false);
  });

  it("allows read tools in plan mode", () => {
    expect(shouldAutoApprove("plan", "read", {})).toBe(true);
  });

  it("blocks write tools in plan mode", () => {
    expect(shouldAutoApprove("plan", "write", {})).toBe(false);
  });
});

describe("plan mode tool filter", () => {
  it("allows Jac MCP read tools", () => {
    expect(isToolAllowedInPlanMode("search_docs")).toBe(true);
    expect(isToolAllowedInPlanMode("validate_jac")).toBe(true);
  });

  it("rejects edit tools", () => {
    expect(isToolAllowedInPlanMode("write")).toBe(false);
    expect(isToolAllowedInPlanMode("bash")).toBe(false);
  });
});

describe("mode parsing", () => {
  it("parses --mode flag", () => {
    expect(parseModeFlag(["--mode", "yolo"])).toBe("yolo");
    expect(parseModeFlag(["--mode=plan"])).toBe("plan");
  });

  it("returns error object for invalid mode", () => {
    expect(parseModeFlag(["--mode", "turbo"])).toEqual({ error: "turbo" });
  });

  it("cycles modes in order", () => {
    expect(cycleMode("normal")).toBe("auto-accept");
    expect(cycleMode("auto-accept")).toBe("yolo");
    expect(cycleMode("yolo")).toBe("plan");
    expect(cycleMode("plan")).toBe("normal");
  });
});
