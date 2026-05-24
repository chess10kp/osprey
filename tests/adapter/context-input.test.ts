import { mkdir, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { expandContextInput } from "../../src/workflow/context-input.js";

describe("expandContextInput", () => {
  let testDir: string;

  beforeEach(async () => {
    testDir = join(tmpdir(), `jackal-context-${Date.now()}`);
    await mkdir(testDir, { recursive: true });
    await writeFile(
      join(testDir, "sample.txt"),
      "line1\nline2\nline3\nline4\nline5\n",
      "utf-8",
    );
  });

  afterEach(async () => {
    await rm(testDir, { recursive: true, force: true });
  });

  it("expands @file line range", async () => {
    const out = await expandContextInput(testDir, "Review @sample.txt:2-4");
    expect(out).toContain('path="sample.txt:2-4"');
    expect(out).toContain("line2");
    expect(out).toContain("line4");
    expect(out).not.toContain("line1");
  });

  it("expands !command output", async () => {
    const out = await expandContextInput(testDir, "!echo hello");
    expect(out).toContain("<command_output>");
    expect(out).toContain("hello");
  });

  it("warns on large attachments", async () => {
    const big = "x".repeat(50_000);
    await writeFile(join(testDir, "big.txt"), big, "utf-8");
    const out = await expandContextInput(testDir, "see @big.txt");
    expect(out).toContain("[Warning: attached files");
  });
});
