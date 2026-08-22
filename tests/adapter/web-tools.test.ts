import { describe, expect, it } from "vitest";
import {
  assertSafeFetchUrl,
  formatWebSearchResponse,
  formatWebSearchResults,
} from "../../src/agent/web-tools.js";

describe("assertSafeFetchUrl", () => {
  it("allows public https URLs", () => {
    expect(assertSafeFetchUrl("https://example.com/docs").href).toBe("https://example.com/docs");
  });

  it("blocks localhost and private IPs", () => {
    expect(() => assertSafeFetchUrl("http://localhost/admin")).toThrow(/loopback/i);
    expect(() => assertSafeFetchUrl("http://127.0.0.1/")).toThrow(/loopback/i);
    expect(() => assertSafeFetchUrl("http://192.168.1.1/")).toThrow(/private/i);
    expect(() => assertSafeFetchUrl("http://10.0.0.5/")).toThrow(/private/i);
  });

  it("blocks non-http schemes", () => {
    expect(() => assertSafeFetchUrl("file:///etc/passwd")).toThrow(/http/i);
  });
});

describe("formatWebSearchResults", () => {
  it("formats numbered results", () => {
    const text = formatWebSearchResults([
      { title: "Doc", url: "https://x.test", snippet: "summary" },
    ]);
    expect(text).toContain("1. Doc");
    expect(text).toContain("https://x.test");
    expect(text).toContain("summary");
  });

  it("handles empty results", () => {
    expect(formatWebSearchResults([])).toBe("No results found.");
  });
});

describe("formatWebSearchResponse", () => {
  it("prefers the synthesized answer plus sources", () => {
    const text = formatWebSearchResponse({
      answer: "Pi-web-access supports many providers.",
      provider: "exa",
      results: [{ title: "Repo", url: "https://github.com/x/y", snippet: "desc" }],
    });
    expect(text).toContain("Pi-web-access supports many providers.");
    expect(text).toContain("1. Repo");
    expect(text).toContain("https://github.com/x/y");
  });

  it("falls back to sources when there is no answer", () => {
    const text = formatWebSearchResponse({
      answer: "",
      results: [{ title: "Only", url: "https://only.test" }],
    });
    expect(text).toContain("1. Only");
  });

  it("reports no results for an empty response", () => {
    expect(formatWebSearchResponse({ answer: "", results: [] })).toBe("No results found.");
  });
});
