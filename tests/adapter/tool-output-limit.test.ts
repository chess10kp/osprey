import { describe, expect, it, vi } from "vitest";
import {
  MAX_TOOL_OUTPUT_BYTES,
  truncateToolOutput,
  truncateToolPayload,
  limitToolResultContent,
  wrapToolOutputLimit,
} from "../../src/runtime/tool-output-limit.js";

describe("truncateToolOutput", () => {
  it("passes through text under the byte limit", () => {
    expect(truncateToolOutput("hello")).toBe("hello");
  });

  it("truncates at 50 KiB using UTF-8 byte length", () => {
    const big = "x".repeat(MAX_TOOL_OUTPUT_BYTES + 1000);
    const out = truncateToolOutput(big);
    expect(Buffer.byteLength(out, "utf8")).toBeLessThanOrEqual(MAX_TOOL_OUTPUT_BYTES);
    expect(out).toContain("...[truncated at 50 KB]");
  });

  it("does not split a multi-byte code point", () => {
    const emoji = "😀".repeat(20_000);
    const out = truncateToolOutput(emoji);
    expect(() => Buffer.from(out, "utf8").toString("utf8")).not.toThrow();
    expect(Buffer.byteLength(out, "utf8")).toBeLessThanOrEqual(MAX_TOOL_OUTPUT_BYTES);
  });
});

describe("truncateToolPayload", () => {
  it("truncates JSON-serialized objects", () => {
    const payload = { stdout: "y".repeat(MAX_TOOL_OUTPUT_BYTES) };
    const out = truncateToolPayload(payload)!;
    expect(out).toContain("...[truncated at 50 KB]");
  });

  it("extracts error field from tool failures", () => {
    expect(truncateToolPayload({ error: "boom" })).toBe("boom");
  });
});

describe("wrapToolOutputLimit", () => {
  it("caps execute() content returned to the agent", async () => {
    const tool = wrapToolOutputLimit({
      name: "test",
      label: "Test",
      description: "test",
      parameters: {},
      execute: async () => ({
        content: [{ type: "text", text: "z".repeat(MAX_TOOL_OUTPUT_BYTES + 500) }],
        details: { ok: true },
      }),
    });

    const result = await tool.execute("id", {});
    const text = result.content?.[0]?.type === "text" ? result.content[0].text : "";
    expect(text).toContain("...[truncated at 50 KB]");
    expect(Buffer.byteLength(text, "utf8")).toBeLessThanOrEqual(MAX_TOOL_OUTPUT_BYTES);
  });

  it("limitToolResultContent is idempotent for small payloads", () => {
    const limited = limitToolResultContent({
      content: [{ type: "text", text: "ok" }],
      details: { n: 1 },
    });
    expect(limited.content?.[0]).toMatchObject({ type: "text", text: "ok" });
  });
});

describe("wrapToolOutputLimit passthrough", () => {
  it("delegates to the original execute", async () => {
    const execute = vi.fn(async () => ({
      content: [{ type: "text", text: "done" }],
    }));
    const tool = wrapToolOutputLimit({
      name: "t",
      label: "T",
      description: "d",
      parameters: {},
      execute,
    });
    await tool.execute("call-1", { a: 1 });
    expect(execute).toHaveBeenCalledWith("call-1", { a: 1 }, undefined, undefined);
  });
});
