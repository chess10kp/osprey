import { describe, expect, it } from "vitest";
import {
  parseMarkdownParts,
  parseMarkdownTable,
} from "../../templates/markdown.mjs";

const mockColors = {
  primary: "green",
  secondary: "gray",
  info: "cyan",
  text: "white",
  tool: "blue",
};

describe("parseMarkdownTable", () => {
  it("renders a simple two-column table with borders", () => {
    const table = `| Name | Age |
|------|-----|
| John | 25  |
| Jane | 30  |`;
    const result = parseMarkdownTable(table, mockColors, 80);
    expect(result).toMatch(/Name/);
    expect(result).toMatch(/Age/);
    expect(result).toMatch(/John/);
    expect(result).toMatch(/Jane/);
    expect(result).toMatch(/25/);
    expect(result).toMatch(/30/);
    expect(result).toMatch(/[─│]/);
  });

  it("returns original text for invalid table input", () => {
    const table = "Not a table at all";
    expect(parseMarkdownTable(table, mockColors)).toBe(table);
  });

  it("strips markdown formatting from cells", () => {
    const table = `| Command | Description |
|---------|-------------|
| \`npm install\` | Install **dependencies** |`;
    const result = parseMarkdownTable(table, mockColors, 100);
    expect(result).toMatch(/npm install/);
    expect(result).toMatch(/dependencies/);
    expect(result).not.toMatch("**dependencies**");
    expect(result).not.toMatch("`npm install`");
  });

  it("handles alignment markers in separator row", () => {
    const table = `| Left | Center | Right |
|:-----|:------:|------:|
| A    | B      | C     |`;
    const result = parseMarkdownTable(table, mockColors, 100);
    expect(result).toMatch(/Left/);
    expect(result).toMatch(/Center/);
    expect(result).toMatch(/Right/);
  });
});

describe("parseMarkdownParts with tables", () => {
  it("includes rendered table in text parts", () => {
    const md = `Here is a table:

| Tool | Status |
|------|--------|
| read | Done   |
| write | Done  |

Done.`;

    const parts = parseMarkdownParts(md, mockColors, 100);
    const text = parts.map((p) => p.content).join("\n");
    expect(parts.some((p) => p.type === "text")).toBe(true);
    expect(text).toMatch(/Tool/);
    expect(text).toMatch(/Status/);
    expect(text).toMatch(/read/);
    expect(text).toMatch(/write/);
    expect(text).toMatch(/[─│]/);
  });

  it("parses tables without a trailing newline on the last row", () => {
    const md = `| Name | Value |
|------|-------|
| foo  | bar   |`;
    const parts = parseMarkdownParts(md, mockColors, 100);
    const text = parts.map((p) => p.content).join("\n");
    expect(text).toMatch(/foo/);
    expect(text).toMatch(/bar/);
    expect(text).toMatch(/[─│]/);
    expect(text).not.toMatch("|------|");
  });
});
