import { describe, expect, it } from "vitest";
import {
  getCurrentFileMention,
  isValidFilePath,
  parseFileMentions,
  parseLineRange,
  parseMentionToken,
} from "../../src/workflow/file-mention-parser.js";

describe("parseFileMentions", () => {
  it("parses path and line range", () => {
    const mentions = parseFileMentions("see @src/foo.jac:10-20 please");
    expect(mentions).toHaveLength(1);
    expect(mentions[0]!.filePath).toBe("src/foo.jac");
    expect(mentions[0]!.lineRange).toEqual({ start: 10, end: 20 });
  });

  it("parses single line", () => {
    const mentions = parseFileMentions("@app.jac:5");
    expect(mentions[0]!.lineRange).toEqual({ start: 5, end: undefined });
  });

  it("rejects invalid line ranges", () => {
    const mentions = parseFileMentions("@app.jac:20-10");
    expect(mentions[0]!.lineRange).toBeUndefined();
  });

  it("parses multiple mentions", () => {
    const mentions = parseFileMentions("Compare @a.ts and @b.ts");
    expect(mentions.map((m) => m.filePath)).toEqual(["a.ts", "b.ts"]);
  });
});

describe("getCurrentFileMention", () => {
  it("finds mention at cursor", () => {
    const input = "Fix @src/ap";
    const mention = getCurrentFileMention(input, 11);
    expect(mention?.mention).toBe("src/ap");
    expect(mention?.start).toBe(4);
  });

  it("preserves partial line range suffix", () => {
    const input = "Check @app.jac:10-";
    const mention = getCurrentFileMention(input, input.length);
    expect(mention?.mention).toBe("app.jac");
    expect(mention?.rangeSuffix).toBe(":10-");
  });
});

describe("parseMentionToken", () => {
  it("splits path and range", () => {
    expect(parseMentionToken("src/foo.jac:3-7")).toEqual({
      path: "src/foo.jac",
      startLine: 3,
      endLine: 7,
    });
  });
});

describe("isValidFilePath", () => {
  it("rejects traversal", () => {
    expect(isValidFilePath("../etc/passwd")).toBe(false);
  });
});

describe("parseLineRange", () => {
  it("parses ranges", () => {
    expect(parseLineRange("10-20")).toEqual({ start: 10, end: 20 });
    expect(parseLineRange("10")).toEqual({ start: 10 });
    expect(parseLineRange("20-10")).toBeNull();
  });
});
