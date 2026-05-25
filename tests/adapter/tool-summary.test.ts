import { describe, expect, it } from "vitest";
import {
  enrichToolInputFromResult,
  formatToolSummary,
  normalizeToolInput,
  toolEventInput,
} from "../../src/core/tool-summary.js";

describe("normalizeToolInput", () => {
  it("parses JSON string args from pi-agent", () => {
    expect(normalizeToolInput('{"path":"src/foo.jac"}')).toEqual({ path: "src/foo.jac" });
  });

  it("accepts plain objects", () => {
    expect(normalizeToolInput({ command: "git status" })).toEqual({ command: "git status" });
  });
});

describe("formatToolSummary", () => {
  it("formats core tools with paths and commands", () => {
    expect(formatToolSummary("read", { path: "lib/foo.jac" })).toBe("Read @ lib/foo.jac");
    expect(formatToolSummary("write", { path: "out.txt" })).toBe("Wrote → out.txt");
    expect(formatToolSummary("bash", { command: "npm test" })).toBe("$ npm test");
  });

  it("formats web tools", () => {
    expect(formatToolSummary("web_search", { search_term: "jac lang release" })).toBe(
      "Web search: jac lang release",
    );
    expect(formatToolSummary("web_fetch", { url: "https://docs.jaseci.org" })).toBe(
      "Fetched https://docs.jaseci.org",
    );
  });

  it("formats update_task with task id and status", () => {
    expect(
      formatToolSummary("update_task", {
        updates: [{ id: "t1", status: "in_progress" }],
      }),
    ).toBe("Task t1 → in_progress");
  });
});

describe("toolEventInput", () => {
  it("reads args from pi-agent events", () => {
    expect(toolEventInput({ args: { path: "a.jac" } })).toEqual({ path: "a.jac" });
  });
});

describe("enrichToolInputFromResult", () => {
  it("fills path from result.details when args were missing", () => {
    const input = enrichToolInputFromResult("write", undefined, {
      content: [{ type: "text", text: "Wrote x" }],
      details: { path: "src/x.jac", bytes: 10 },
    });
    expect(input).toEqual({ path: "src/x.jac" });
    expect(formatToolSummary("write", input)).toBe("Wrote → src/x.jac");
  });

  it("fills bash command from result.details", () => {
    const input = enrichToolInputFromResult("bash", undefined, {
      content: [{ type: "text", text: "ok" }],
      details: { command: "git status", code: 0 },
    });
    expect(formatToolSummary("bash", input)).toBe("$ git status");
  });
});
