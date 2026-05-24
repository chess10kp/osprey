import { describe, expect, it } from "vitest";
import { formatApprovalDisplay } from "../../src/ui/approval-display.js";

describe("formatApprovalDisplay", () => {
  it("summarizes bash with command line", () => {
    const d = formatApprovalDisplay("bash", { command: "git status" });
    expect(d.headline).toContain("bash");
    expect(d.detailLines.some((l) => l.includes("git status"))).toBe(true);
    expect(d.previewLines.some((l) => l.text.includes("git status"))).toBe(true);
    expect(d.question).toContain("bash");
  });

  it("summarizes write with path", () => {
    const d = formatApprovalDisplay("write", { path: "src/foo.jac", content: "walker init;\n" });
    expect(d.headline).toContain("src/foo.jac");
    expect(d.detailLines.some((l) => l.includes("Bytes:"))).toBe(true);
    expect(d.previewLines.some((l) => l.text.includes("walker init"))).toBe(true);
  });

  it("shows edit diff preview for edits array", () => {
    const d = formatApprovalDisplay("edit", {
      path: "a.jac",
      edits: [{ oldText: "foo", newText: "bar" }],
    });
    expect(d.previewLines.some((l) => l.tone === "removed" && l.text.includes("foo"))).toBe(true);
    expect(d.previewLines.some((l) => l.tone === "added" && l.text.includes("bar"))).toBe(true);
  });

  it("includes subagent name", () => {
    const d = formatApprovalDisplay("read", { path: "x.jac" }, { subagentName: "scout" });
    expect(d.detailLines[0]).toContain("scout");
    expect(d.previewLines[0]?.text).toContain("scout");
  });
});
