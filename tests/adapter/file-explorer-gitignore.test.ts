import { mkdir, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { listProjectFiles } from "../../src/project/file-explorer.js";

describe("listProjectFiles gitignore", () => {
  let testDir: string;

  beforeEach(async () => {
    testDir = join(tmpdir(), `jackal-files-${Date.now()}`);
    await mkdir(testDir, { recursive: true });
    await writeFile(join(testDir, "keep.txt"), "ok", "utf-8");
    await mkdir(join(testDir, "ignored"), { recursive: true });
    await writeFile(join(testDir, "ignored", "skip.txt"), "no", "utf-8");
    await writeFile(join(testDir, ".gitignore"), "ignored/\n", "utf-8");
  });

  afterEach(async () => {
    await rm(testDir, { recursive: true, force: true });
  });

  it("skips paths matched by .gitignore", async () => {
    const files = await listProjectFiles(testDir);
    expect(files).toContain("keep.txt");
    expect(files.some((f) => f.includes("ignored"))).toBe(false);
  });
});
