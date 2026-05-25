import { describe, expect, it } from "vitest";
import {
  matchPattern,
  evaluatePermissionPatterns,
  loadPermissionPatterns,
  SessionPermissions,
  createPendingApproval,
  isApprovalExpired,
  type PermissionPattern,
} from "../../src/agent/session-permissions.js";
import type { JackalProjectConfig } from "../../src/config/project-config.js";

describe("matchPattern", () => {
  describe("glob", () => {
    it("matches wildcard", () => {
      expect(matchPattern("src/main.jac", "*.jac", "glob")).toBe(true);
    });

    it("matches nested wildcard", () => {
      expect(matchPattern("src/deep/nested.jac", "src/**/*.jac", "glob")).toBe(true);
    });

    it("rejects non-matching extension", () => {
      expect(matchPattern("test.py", "*.jac", "glob")).toBe(false);
    });

    it("star matches everything", () => {
      expect(matchPattern("anything", "*", "glob")).toBe(true);
      expect(matchPattern("", "*", "glob")).toBe(true);
    });
  });

  describe("regex", () => {
    it("matches start-of-line", () => {
      expect(matchPattern("npm install react", "^npm install", "regex")).toBe(true);
    });

    it("rejects non-matching position", () => {
      expect(matchPattern("echo npm install", "^npm install", "regex")).toBe(false);
    });

    it("handles complex regex", () => {
      expect(matchPattern("git commit -m 'fix'", "git\\s+commit", "regex")).toBe(true);
    });

    it("returns false for invalid regex", () => {
      expect(matchPattern("test", "([invalid", "regex")).toBe(false);
    });
  });

  describe("exact", () => {
    it("matches identical strings", () => {
      expect(matchPattern("git status", "git status", "exact")).toBe(true);
    });

    it("rejects different strings", () => {
      expect(matchPattern("git status --short", "git status", "exact")).toBe(false);
    });
  });

  describe("prefix", () => {
    it("matches when resource starts with pattern", () => {
      expect(matchPattern("npm install react-dom", "npm install", "prefix")).toBe(true);
    });

    it("rejects when resource does not start with pattern", () => {
      expect(matchPattern("echo npm install", "npm install", "prefix")).toBe(false);
    });
  });

  describe("edge cases", () => {
    it("empty pattern does not match non-empty resource", () => {
      expect(matchPattern("test", "", "glob")).toBe(false);
    });

    it("empty resource does not match non-star pattern", () => {
      expect(matchPattern("", "*.jac", "glob")).toBe(false);
    });
  });
});

describe("evaluatePermissionPatterns", () => {
  const patterns: PermissionPattern[] = [
    { tool: "bash", pattern: "rm -rf *", type: "glob", action: "deny" },
    { tool: "bash", pattern: "git *", type: "glob", action: "allow" },
    { tool: "write", pattern: "src/**", type: "glob", action: "allow" },
    { tool: "*", pattern: "*.log", type: "glob", action: "deny" },
  ];

  it("deny takes precedence over allow", () => {
    expect(evaluatePermissionPatterns(patterns, "bash", "rm -rf /home")).toBe("deny");
  });

  it("allows matching patterns", () => {
    expect(evaluatePermissionPatterns(patterns, "bash", "git status")).toBe("allow");
  });

  it("allows write to src files", () => {
    expect(evaluatePermissionPatterns(patterns, "write", "src/app.ts")).toBe("allow");
  });

  it("returns null for no match", () => {
    expect(evaluatePermissionPatterns(patterns, "bash", "echo hello")).toBeNull();
  });

  it("wildcard tool matches any tool", () => {
    expect(evaluatePermissionPatterns(patterns, "mcp", "debug.log")).toBe("deny");
  });

  it("deny immediately blocks even if allow also matches", () => {
    const mixed: PermissionPattern[] = [
      { tool: "*", pattern: "*", type: "glob", action: "allow" },
      { tool: "bash", pattern: "rm *", type: "glob", action: "deny" },
    ];
    expect(evaluatePermissionPatterns(mixed, "bash", "rm -rf /")).toBe("deny");
  });
});

describe("loadPermissionPatterns", () => {
  it("loads patterns from project config", () => {
    const config: JackalProjectConfig = {
      permissionPatterns: [
        { tool: "bash", pattern: "git *", action: "allow" },
        { tool: "write", pattern: "*.test.ts", type: "glob", action: "deny" },
      ],
    };
    const patterns = loadPermissionPatterns(config);
    expect(patterns).toHaveLength(2);
    expect(patterns[0]!.tool).toBe("bash");
    expect(patterns[0]!.type).toBe("glob"); // default
    expect(patterns[1]!.action).toBe("deny");
  });

  it("returns empty for missing config", () => {
    expect(loadPermissionPatterns()).toEqual([]);
    expect(loadPermissionPatterns({})).toEqual([]);
  });

  it("skips malformed entries", () => {
    const config: JackalProjectConfig = {
      permissionPatterns: [
        { tool: "bash", pattern: "git *" },
        { tool: 123, pattern: "bad" } as unknown as { tool: string; pattern: string },
        null as unknown as { tool: string; pattern: string },
      ],
    };
    const patterns = loadPermissionPatterns(config);
    expect(patterns).toHaveLength(1);
  });
});

describe("SessionPermissions", () => {
  it("grants and checks exact tool names", () => {
    const sp = new SessionPermissions();
    expect(sp.isGranted("bash")).toBe(false);
    sp.grant("bash");
    expect(sp.isGranted("bash")).toBe(true);
  });

  it("clears all grants", () => {
    const sp = new SessionPermissions();
    sp.grant("bash");
    sp.grant("write");
    sp.clear();
    expect(sp.isGranted("bash")).toBe(false);
    expect(sp.isGranted("write")).toBe(false);
  });

  it("grants and checks pattern-based permissions", () => {
    const sp = new SessionPermissions();
    sp.grantPattern("bash", "git *", "glob");
    expect(sp.isGrantedByPattern("bash", "git status")).toBe(true);
    expect(sp.isGrantedByPattern("bash", "rm -rf /")).toBe(false);
  });

  it("wildcard pattern grants work for any tool", () => {
    const sp = new SessionPermissions();
    sp.grantPattern("*", "safe_", "prefix");
    expect(sp.isGrantedByPattern("mcp", "safe_tool")).toBe(true);
    expect(sp.isGrantedByPattern("bash", "unsafe_command")).toBe(false);
  });

  it("deduplicates pattern grants", () => {
    const sp = new SessionPermissions();
    sp.grantPattern("bash", "git *", "glob");
    sp.grantPattern("bash", "git *", "glob");
    const patterns = sp.grantedPatterns();
    expect(patterns.get("bash")).toHaveLength(1);
  });
});

describe("PendingApproval", () => {
  it("creates pending approval with correct fields", () => {
    const a = createPendingApproval("bash", "rm -rf /tmp", "preview text");
    expect(a.toolName).toBe("bash");
    expect(a.resource).toBe("rm -rf /tmp");
    expect(a.contentPreview).toBe("preview text");
    expect(a.state).toBe("pending");
    expect(a.id).toBeTruthy();
  });

  it("truncates content preview to 512 chars", () => {
    const long = "x".repeat(1000);
    const a = createPendingApproval("write", "test.ts", long);
    expect(a.contentPreview.length).toBeLessThanOrEqual(512);
  });

  it("detects expired approvals", () => {
    const a = createPendingApproval("bash", "test");
    a.createdAt = Date.now() - 600_000; // 10 min ago
    expect(isApprovalExpired(a, 300_000)).toBe(true);
  });

  it("non-pending approvals are not expired", () => {
    const a = createPendingApproval("bash", "test");
    a.state = "approved";
    a.createdAt = Date.now() - 600_000;
    expect(isApprovalExpired(a, 300_000)).toBe(false);
  });
});
