import { describe, expect, it } from "vitest";
import {
  assertSafeFetchUrl,
  formatWebSearchResults,
  htmlToReadableText,
  parseBraveSearchResponse,
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

describe("htmlToReadableText", () => {
  it("strips tags and scripts", () => {
    const html = "<html><head><script>alert(1)</script></head><body><h1>Hi</h1><p>There</p></body></html>";
    const text = htmlToReadableText(html);
    expect(text).toContain("Hi");
    expect(text).toContain("There");
    expect(text).not.toContain("alert");
    expect(text).not.toContain("<");
  });
});

describe("parseBraveSearchResponse", () => {
  it("extracts web results", () => {
    const data = {
      web: {
        results: [
          { title: "A", url: "https://a.test", description: "alpha" },
          { title: "B", url: "https://b.test", snippet: "beta" },
        ],
      },
    };
    expect(parseBraveSearchResponse(data)).toEqual([
      { title: "A", url: "https://a.test", description: "alpha" },
      { title: "B", url: "https://b.test", description: "beta" },
    ]);
  });
});

describe("formatWebSearchResults", () => {
  it("formats numbered results", () => {
    const text = formatWebSearchResults([
      { title: "Doc", url: "https://x.test", description: "summary" },
    ]);
    expect(text).toContain("1. Doc");
    expect(text).toContain("https://x.test");
    expect(text).toContain("summary");
  });
});
