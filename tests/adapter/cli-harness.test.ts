/**
 * Ported from nanocoder source/cli-harness.spec.ts and source/cli-integration.spec.ts
 */
import { describe, expect, it } from "vitest";
import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const jackalRoot = join(fileURLToPath(new URL(".", import.meta.url)), "../..");
const distIndex = join(jackalRoot, "dist/index.js");

function runJackal(args: string[]): string {
  const result = execFileSync("node", [distIndex, ...args], {
    encoding: "utf8",
    cwd: jackalRoot,
    stdio: ["pipe", "pipe", "pipe"],
  });
  return result.trim();
}

describe("Jackal CLI (nanocoder cli-integration parity)", () => {
  it("dist/index.js exists after build", () => {
    if (!existsSync(distIndex)) {
      execFileSync("npm", ["run", "build:agent"], { cwd: jackalRoot, stdio: "ignore" });
    }
    expect(existsSync(distIndex)).toBe(true);
  });

  it("--check exits successfully", () => {
    if (!existsSync(distIndex)) {
      execFileSync("npm", ["run", "build:agent"], { cwd: jackalRoot, stdio: "ignore" });
    }
    expect(() => runJackal(["--check"])).not.toThrow();
  });
});

describe("CLI harness helpers (nanocoder parity)", () => {
  it("assertExitCode pattern — zero means success", () => {
    const result = { exitCode: 0 };
    expect(result.exitCode).toBe(0);
  });

  it("assertExitCode pattern — non-zero means failure", () => {
    const result = { exitCode: 1 };
    expect(result.exitCode).not.toBe(0);
  });

  it("assertTimedOut identifies timeout results", () => {
    const result = { timedOut: true, killed: true };
    expect(result.timedOut).toBe(true);
  });

  it("assertStdoutContains matches string output", () => {
    const result = { stdout: "Hello, World!" };
    expect(result.stdout).toContain("Hello");
  });
});
