import { describe, expect, it } from "vitest";
import { formatApprovalDisplay } from "../../src/ui/approval-display.js";

describe("formatApprovalDisplay", () => {
  it("summarizes bash with command line", () => {
    const d = formatApprovalDisplay("bash", { command: "git status" });
    expect(d.headline).toContain("bash");
    expect(d.detailLines.some((l) => l.includes("git status"))).toBe(true);
  });

  it("summarizes write with path", () => {
    const d = formatApprovalDisplay("write", { path: "src/foo.jac" });
    expect(d.headline).toContain("src/foo.jac");
    expect(d.detailLines.some((l) => l.includes("Path:"))).toBe(true);
  });

  it("includes subagent name", () => {
    const d = formatApprovalDisplay("read", { path: "x.jac" }, { subagentName: "scout" });
    expect(d.detailLines[0]).toContain("scout");
  });
});
