import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { describe, expect, it } from "vitest";
import {
  SessionPermissions,
  loadAlwaysAllowTools,
  needsToolApproval,
} from "../../src/agent/session-permissions.js";

describe("SessionPermissions", () => {
  it("grants and checks tool names", () => {
    const perms = new SessionPermissions();
    expect(perms.isGranted("bash")).toBe(false);
    perms.grant("bash");
    expect(perms.isGranted("bash")).toBe(true);
    expect(perms.isGranted("write")).toBe(false);
  });

  it("clears session grants", () => {
    const perms = new SessionPermissions();
    perms.grant("read");
    perms.clear();
    expect(perms.isGranted("read")).toBe(false);
    expect(perms.grantedTools()).toEqual([]);
  });
});

describe("loadAlwaysAllowTools", () => {
  it("merges project and MCP alwaysAllow lists", () => {
    const cwd = mkdtempSync(join(tmpdir(), "jackal-perms-"));
    mkdirSync(join(cwd, "pi"), { recursive: true });
    writeFileSync(join(cwd, ".jackal"), JSON.stringify({ alwaysAllow: ["read"] }));
    writeFileSync(
      join(cwd, "pi", "mcp.json"),
      JSON.stringify({
        mcpServers: {
          jac: { alwaysAllow: ["validate_jac"] },
        },
      }),
    );

    const allowed = loadAlwaysAllowTools(cwd, { alwaysAllow: ["read"] });
    expect(allowed.has("read")).toBe(true);
    expect(allowed.has("validate_jac")).toBe(true);
    expect(allowed.has("bash")).toBe(false);
  });
});

describe("needsToolApproval", () => {
  it("skips approval when tool is granted for the session", () => {
    const perms = new SessionPermissions();
    perms.grant("bash");
    expect(
      needsToolApproval("normal", "bash", { command: "npm test" }, {
        sessionPermissions: perms,
      }),
    ).toBe(false);
  });

  it("still requires approval in normal mode without a session grant", () => {
    const perms = new SessionPermissions();
    expect(
      needsToolApproval("normal", "bash", { command: "npm test" }, {
        sessionPermissions: perms,
      }),
    ).toBe(true);
  });

  it("respects config alwaysAllow without session grant", () => {
    const alwaysAllow = new Set(["read"]);
    expect(needsToolApproval("normal", "read", {}, { alwaysAllow })).toBe(false);
    expect(needsToolApproval("normal", "write", {}, { alwaysAllow })).toBe(true);
  });

  it("respects dev mode auto-approve policy", () => {
    expect(needsToolApproval("yolo", "bash", { command: "rm -rf /" }, {})).toBe(
      false,
    );
    expect(
      needsToolApproval("auto-accept", "bash", { command: "npm test" }, {}),
    ).toBe(false);
    expect(
      needsToolApproval("auto-accept", "bash", { command: "git push --force" }, {}),
    ).toBe(true);
  });

  it("session grants apply to subagent tool checks too", () => {
    const perms = new SessionPermissions();
    perms.grant("write");
    expect(
      needsToolApproval("normal", "write", { path: "foo.jac" }, {
        sessionPermissions: perms,
      }),
    ).toBe(false);
  });
});
