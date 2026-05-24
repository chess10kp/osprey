import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { afterEach, describe, expect, it } from "vitest";
import { pruneSessions, type SessionIndexEntry } from "../../src/session/session-index.js";

describe("pruneSessions", () => {
  const dirs: string[] = [];

  afterEach(() => {
    for (const dir of dirs) {
      try {
        rmSync(dir, { recursive: true, force: true });
      } catch {
        /* ignore */
      }
    }
    dirs.length = 0;
  });

  function makeSessionDir(entries: SessionIndexEntry[]): string {
    const dir = join(tmpdir(), `jackal-sessions-${String(Date.now())}-${String(Math.random()).slice(2)}`);
    mkdirSync(dir, { recursive: true });
    dirs.push(dir);
    writeFileSync(join(dir, "index.json"), JSON.stringify(entries, null, 2) + "\n");
    for (const entry of entries) {
      writeFileSync(join(dir, `${entry.id}.json`), JSON.stringify({ sessionId: entry.id }));
    }
    return dir;
  }

  it("prunes sessions beyond maxCount", () => {
    const now = Date.now();
    const entries: SessionIndexEntry[] = [
      { id: "sess_3", name: "new", cwd: "/p", updatedAt: new Date(now).toISOString(), messageCount: 1 },
      { id: "sess_2", name: "mid", cwd: "/p", updatedAt: new Date(now - 1000).toISOString(), messageCount: 1 },
      { id: "sess_1", name: "old", cwd: "/p", updatedAt: new Date(now - 2000).toISOString(), messageCount: 1 },
    ];
    const dir = makeSessionDir(entries);
    const pruned = pruneSessions(dir, { maxCount: 2 });
    expect(pruned).toContain("sess_1");
    expect(existsSync(join(dir, "sess_1.json"))).toBe(false);
    const index = JSON.parse(readFileSync(join(dir, "index.json"), "utf-8")) as SessionIndexEntry[];
    expect(index.map((e) => e.id)).toEqual(["sess_3", "sess_2"]);
  });

  it("prunes sessions older than retentionDays", () => {
    const old = new Date(Date.now() - 40 * 24 * 60 * 60 * 1000).toISOString();
    const recent = new Date().toISOString();
    const entries: SessionIndexEntry[] = [
      { id: "sess_2", name: "recent", cwd: "/p", updatedAt: recent, messageCount: 1 },
      { id: "sess_1", name: "stale", cwd: "/p", updatedAt: old, messageCount: 1 },
    ];
    const dir = makeSessionDir(entries);
    const pruned = pruneSessions(dir, { retentionDays: 30 });
    expect(pruned).toEqual(["sess_1"]);
    expect(existsSync(join(dir, "sess_1.json"))).toBe(false);
  });
});
