import { describe, expect, it } from "vitest";
import {
  wrapPlainText,
  wrapWithTrimmedContinuations,
} from "../../templates/text-wrapping.mjs";

describe("text-wrapping", () => {
  it("wraps long lines without breaking short text", () => {
    const short = wrapWithTrimmedContinuations("hello world", 40);
    expect(short).toBe("hello world");
  });

  it("wraps plain text to width", () => {
    const long = "word ".repeat(30).trim();
    const wrapped = wrapPlainText(long, 20);
    expect(wrapped.split("\n").length).toBeGreaterThan(1);
  });
});
