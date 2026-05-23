// Session index — list, load, and resolve sessions under .jackal/sessions/.

import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { join, normalize, resolve } from "node:path";
import type { AgentMessage } from "@earendil-works/pi-agent-core";

export interface SessionIndexEntry {
  id: string;
  name: string;
  cwd: string;
  updatedAt: string;
  messageCount: number;
  model?: { provider: string; id: string };
}

export interface SessionRecord {
  sessionId: string;
  sessionName: string;
  cwd: string;
  createdAt: string;
  updatedAt: string;
  model?: { provider: string; id: string };
  messages: AgentMessage[];
}

const INDEX_FILE = "index.json";
const SESSION_ID_PATTERN = /^sess_[0-9]+$/;

function isValidSessionId(id: string): boolean {
  return SESSION_ID_PATTERN.test(id);
}

function readJsonFile<T>(path: string): T | null {
  if (!existsSync(path)) return null;
  try {
    return JSON.parse(readFileSync(path, "utf-8")) as T;
  } catch {
    return null;
  }
}

function writeJsonFile(path: string, data: unknown): void {
  writeFileSync(path, JSON.stringify(data, null, 2) + "\n", "utf-8");
}

function isIndexEntry(value: unknown): value is SessionIndexEntry {
  if (!value || typeof value !== "object") return false;
  const v = value as Record<string, unknown>;
  return (
    typeof v.id === "string" &&
    typeof v.name === "string" &&
    typeof v.cwd === "string" &&
    typeof v.updatedAt === "string" &&
    typeof v.messageCount === "number"
  );
}

function isSessionRecord(value: unknown): value is SessionRecord {
  if (!value || typeof value !== "object") return false;
  const v = value as Record<string, unknown>;
  return (
    typeof v.sessionId === "string" &&
    typeof v.sessionName === "string" &&
    typeof v.cwd === "string" &&
    typeof v.updatedAt === "string" &&
    Array.isArray(v.messages)
  );
}

function indexPath(sessionDir: string): string {
  return join(sessionDir, INDEX_FILE);
}

function sessionFilePath(sessionDir: string, id: string): string {
  return join(sessionDir, `${id}.json`);
}

function readIndex(sessionDir: string): SessionIndexEntry[] {
  const raw = readJsonFile<unknown>(indexPath(sessionDir));
  if (!Array.isArray(raw)) return rebuildIndex(sessionDir);
  const valid = raw.filter(isIndexEntry);
  if (valid.length === 0 && raw.length > 0) return rebuildIndex(sessionDir);
  return valid;
}

function writeIndex(sessionDir: string, entries: SessionIndexEntry[]): void {
  if (!existsSync(sessionDir)) {
    mkdirSync(sessionDir, { recursive: true });
  }
  writeJsonFile(indexPath(sessionDir), entries);
}

function rebuildIndex(sessionDir: string): SessionIndexEntry[] {
  if (!existsSync(sessionDir)) return [];
  const entries: SessionIndexEntry[] = [];
  for (const name of readdirSync(sessionDir)) {
    if (!name.endsWith(".json") || name === INDEX_FILE || name === "latest.json") {
      continue;
    }
    const id = name.slice(0, -5);
    if (!isValidSessionId(id)) continue;
    const record = readJsonFile<unknown>(join(sessionDir, name));
    if (!isSessionRecord(record)) continue;
    entries.push({
      id: record.sessionId,
      name: record.sessionName,
      cwd: record.cwd,
      updatedAt: record.updatedAt,
      messageCount: record.messages.length,
      model: record.model,
    });
  }
  if (entries.length > 0) writeIndex(sessionDir, entries);
  return entries;
}

/** Migrate legacy latest.json into indexed per-session storage. */
export function migrateLegacyLatest(sessionDir: string, cwd: string): SessionRecord | null {
  const legacyPath = join(sessionDir, "latest.json");
  if (!existsSync(legacyPath)) return null;

  const legacy = readJsonFile<{
    sessionId?: string;
    sessionName?: string;
    model?: { provider: string; id: string };
    messages?: AgentMessage[];
  }>(legacyPath);

  if (!legacy?.sessionId) return null;

  const now = new Date().toISOString();
  const record: SessionRecord = {
    sessionId: legacy.sessionId,
    sessionName: legacy.sessionName ?? "session",
    cwd,
    createdAt: now,
    updatedAt: now,
    model: legacy.model,
    messages: legacy.messages ?? [],
  };

  saveSessionRecord(sessionDir, record);
  try {
    unlinkSync(legacyPath);
  } catch {
    /* ignore */
  }
  return record;
}

export function saveSessionRecord(sessionDir: string, record: SessionRecord): void {
  if (!isValidSessionId(record.sessionId)) {
    throw new Error(`Invalid session ID: ${record.sessionId}`);
  }
  if (!existsSync(sessionDir)) {
    mkdirSync(sessionDir, { recursive: true });
  }

  writeJsonFile(sessionFilePath(sessionDir, record.sessionId), record);

  const index = readIndex(sessionDir);
  const entry: SessionIndexEntry = {
    id: record.sessionId,
    name: record.sessionName,
    cwd: record.cwd,
    updatedAt: record.updatedAt,
    messageCount: record.messages.length,
    model: record.model,
  };

  const existing = index.findIndex((e) => e.id === record.sessionId);
  if (existing >= 0) {
    index[existing] = entry;
  } else {
    index.push(entry);
  }
  writeIndex(sessionDir, index);
}

export function listSessions(
  sessionDir: string,
  options?: { cwd?: string },
): SessionIndexEntry[] {
  if (!existsSync(sessionDir)) return [];
  const entries = readIndex(sessionDir);
  const sorted = [...entries].sort(
    (a, b) => new Date(b.updatedAt).getTime() - new Date(a.updatedAt).getTime(),
  );
  if (!options?.cwd) return sorted;
  const normalized = normalize(resolve(options.cwd));
  return sorted.filter((e) => normalize(resolve(e.cwd)) === normalized);
}

export function loadSessionById(sessionDir: string, id: string): SessionRecord | null {
  if (!isValidSessionId(id)) return null;
  const record = readJsonFile<unknown>(sessionFilePath(sessionDir, id));
  return isSessionRecord(record) ? record : null;
}

/** Resolve "last", numeric index (1-based), or raw session id. */
export function resolveSessionTarget(
  sessionDir: string,
  target: string,
  options?: { cwd?: string },
): SessionRecord | null {
  const entries = listSessions(sessionDir, options);
  if (entries.length === 0) return null;

  const lower = target.toLowerCase();
  if (lower === "last") {
    return loadSessionById(sessionDir, entries[0].id);
  }

  const index = Number.parseInt(target, 10);
  if (!Number.isNaN(index) && index >= 1 && index <= entries.length) {
    return loadSessionById(sessionDir, entries[index - 1].id);
  }

  return loadSessionById(sessionDir, target);
}

export function getLastSession(
  sessionDir: string,
  options?: { cwd?: string },
): SessionIndexEntry | null {
  const entries = listSessions(sessionDir, options);
  return entries[0] ?? null;
}

export function deleteSession(sessionDir: string, id: string): boolean {
  if (!isValidSessionId(id)) return false;
  const file = sessionFilePath(sessionDir, id);
  if (existsSync(file)) {
    try {
      unlinkSync(file);
    } catch {
      return false;
    }
  }
  const index = readIndex(sessionDir).filter((e) => e.id !== id);
  writeIndex(sessionDir, index);
  return true;
}
