import { describe, expect, it } from "vitest";
import {
  parseJacCheckOutput,
  findJacBinary,
  findJacBinarySync,
} from "../../src/jac/jac-cli.js";

describe("parseJacCheckOutput", () => {
  it("parses single-line error format", async () => {
    const stdout = "src/foo.jac:10:5: error: undefined name 'x'";
    const diagnostics = await parseJacCheckOutput(stdout, "");
    expect(diagnostics).toHaveLength(1);
    expect(diagnostics[0]).toMatchObject({
      file: "src/foo.jac",
      line: 10,
      column: 5,
      severity: "error",
      message: "undefined name 'x'",
    });
  });

  it("parses multi-line error with location arrow", async () => {
    const stderr = [
      "Error: type mismatch",
      " --> src/bar.jac:3:1",
    ].join("\n");
    const diagnostics = await parseJacCheckOutput("", stderr);
    expect(diagnostics).toHaveLength(1);
    expect(diagnostics[0]).toMatchObject({
      file: "src/bar.jac",
      line: 3,
      column: 1,
      severity: "error",
      message: "type mismatch",
    });
  });

  it("parses warning lines", async () => {
    const stdout = "src/warn.jac:1:1: warning: unused import";
    const diagnostics = await parseJacCheckOutput(stdout, "");
    expect(diagnostics[0]?.severity).toBe("warning");
  });

  it("strips ANSI color codes before parsing", async () => {
    const stdout = "\x1b[31msrc/a.jac:2:3: error: boom\x1b[0m";
    const diagnostics = await parseJacCheckOutput(stdout, "");
    expect(diagnostics[0]?.message).toBe("boom");
  });

  it("returns empty array for clean output", async () => {
    expect(await parseJacCheckOutput("All checks passed", "")).toEqual([]);
  });
});

describe("findJacBinary", () => {
  it("finds jac on PATH when present (sync)", () => {
    const originalPath = process.env.PATH;
    process.env.PATH = "/home/jac/repos/jackal/.venv/bin:" + (originalPath ?? "");
    try {
      expect(findJacBinarySync()).toBe("jac");
    } finally {
      process.env.PATH = originalPath;
    }
  });

  it("returns null when no candidate exists on PATH (sync)", () => {
    const originalPath = process.env.PATH;
    process.env.PATH = "/nonexistent-empty-path";
    try {
      expect(findJacBinarySync()).toBeNull();
    } finally {
      process.env.PATH = originalPath;
    }
  });

  it("finds jac via toolchain bridge (async)", async () => {
    const originalPath = process.env.PATH;
    process.env.PATH = "/home/jac/repos/jackal/.venv/bin:" + (originalPath ?? "");
    try {
      expect(await findJacBinary()).toBe("jac");
    } finally {
      process.env.PATH = originalPath;
    }
  });
});
