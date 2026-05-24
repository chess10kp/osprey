// Lightweight session persistence for the Jackal agent runtime.

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { AgentMessage } from "@earendil-works/pi-agent-core";
import type { Model, Api } from "@earendil-works/pi-ai";
import {
  getLastSession,
  loadSessionById,
  migrateLegacyLatest,
  pruneSessions,
  saveSessionRecord,
  type SessionRecord,
} from "./session-index.js";
import { loadProjectConfig } from "../config/project-config.js";

export interface SessionSnapshot {
  sessionId: string;
  sessionName: string;
  model?: { provider: string; id: string };
  messages: AgentMessage[];
}

export interface SavedModelRef {
  provider: string;
  id: string;
}

export interface JackalSessionOptions {
  autoSave?: boolean;
  saveIntervalMs?: number;
}

const DEFAULT_SAVE_INTERVAL_MS = 30_000;

export class JackalSessionManager {
  private _cwd: string;
  private _sessionDir: string;
  private _sessionId: string;
  private _sessionName: string;
  private _createdAt: string;
  private _messages: AgentMessage[] = [];
  private _model?: Model<Api>;
  private _savedModelRef?: SavedModelRef;
  private _autoSave: boolean;
  private _saveIntervalMs: number;
  private _autoSaveTimer: ReturnType<typeof setInterval> | null = null;
  private _dirty = false;

  private constructor(
    cwd: string,
    sessionDir: string,
    sessionId: string,
    sessionName: string,
    createdAt: string,
    options?: JackalSessionOptions,
  ) {
    this._cwd = cwd;
    this._sessionDir = sessionDir;
    this._sessionId = sessionId;
    this._sessionName = sessionName;
    this._createdAt = createdAt;
    this._autoSave = options?.autoSave ?? true;
    this._saveIntervalMs = Math.max(1000, options?.saveIntervalMs ?? DEFAULT_SAVE_INTERVAL_MS);
  }

  static continueRecent(
    cwd: string,
    sessionDir?: string,
    options?: JackalSessionOptions,
  ): JackalSessionManager {
    const dir = sessionDir ?? join(cwd, ".jackal", "sessions");
    if (!existsSync(dir)) {
      mkdirSync(dir, { recursive: true });
    }

    migrateLegacyLatest(dir, cwd);

    // Prune old sessions based on config
    const cfg = loadProjectConfig(cwd);
    if (cfg.sessions?.maxCount || cfg.sessions?.retentionDays) {
      pruneSessions(dir, {
        maxCount: cfg.sessions.maxCount,
        retentionDays: cfg.sessions.retentionDays,
      });
    }

    const sessionOpts: JackalSessionOptions = {
      autoSave: cfg.sessions?.autoSave ?? options?.autoSave ?? true,
      saveIntervalMs: cfg.sessions?.saveIntervalMs ?? options?.saveIntervalMs,
    };

    const last = getLastSession(dir, { cwd });
    if (last) {
      const loaded = loadSessionById(dir, last.id);
      if (loaded) {
        return JackalSessionManager.fromRecord(cwd, dir, loaded, sessionOpts);
      }
    }

    const now = new Date().toISOString();
    const mgr = new JackalSessionManager(
      cwd,
      dir,
      `sess_${Date.now()}`,
      "session",
      now,
      sessionOpts,
    );
    mgr._startAutoSave();
    return mgr;
  }

  static loadById(
    cwd: string,
    sessionId: string,
    sessionDir?: string,
    options?: JackalSessionOptions,
  ): JackalSessionManager | null {
    const dir = sessionDir ?? join(cwd, ".jackal", "sessions");
    const record = loadSessionById(dir, sessionId);
    if (!record) return null;
    return JackalSessionManager.fromRecord(cwd, dir, record, options);
  }

  static inMemory(cwd?: string): JackalSessionManager {
    return new JackalSessionManager(
      cwd ?? process.cwd(),
      "",
      `mem_${Date.now()}`,
      "memory",
      new Date().toISOString(),
      { autoSave: false },
    );
  }

  private static fromRecord(
    cwd: string,
    sessionDir: string,
    record: SessionRecord,
    options?: JackalSessionOptions,
  ): JackalSessionManager {
    const mgr = new JackalSessionManager(
      cwd,
      sessionDir,
      record.sessionId,
      record.sessionName,
      record.createdAt ?? record.updatedAt,
      options,
    );
    mgr._messages = record.messages ?? [];
    if (record.model?.provider && record.model?.id) {
      mgr._savedModelRef = {
        provider: record.model.provider,
        id: record.model.id,
      };
    }
    mgr._startAutoSave();
    return mgr;
  }

  get cwd(): string {
    return this._cwd;
  }

  get sessionDir(): string {
    return this._sessionDir;
  }

  get sessionId(): string {
    return this._sessionId;
  }

  get sessionName(): string {
    return this._sessionName;
  }

  get messages(): AgentMessage[] {
    return this._messages;
  }

  get model(): Model<Api> | undefined {
    return this._model;
  }

  get savedModelRef(): SavedModelRef | undefined {
    return this._savedModelRef;
  }

  setModel(model: Model<Api>): void {
    this._model = model;
    this._savedModelRef = { provider: model.provider, id: model.id };
    this._markDirty();
    this.flush();
  }

  setMessages(messages: AgentMessage[]): void {
    this._messages = messages;
    this._markDirty();
  }

  rename(name: string): void {
    const trimmed = name.trim();
    if (!trimmed) throw new Error("Session name must be non-empty");
    if (trimmed.length > 100) throw new Error("Session name must be 100 characters or less");
    this._sessionName = trimmed;
    this._markDirty();
    this.flush();
  }

  newSession(): void {
    this.flush();
    this._sessionId = `sess_${Date.now()}`;
    this._sessionName = "new session";
    this._createdAt = new Date().toISOString();
    this._messages = [];
    this._markDirty();
    this.flush();
  }

  /** Apply a loaded session record (resume). */
  applyRecord(record: SessionRecord): void {
    this._sessionId = record.sessionId;
    this._sessionName = record.sessionName;
    this._createdAt = record.createdAt ?? record.updatedAt;
    this._messages = record.messages ?? [];
    if (record.model?.provider && record.model?.id) {
      this._savedModelRef = {
        provider: record.model.provider,
        id: record.model.id,
      };
    } else {
      this._savedModelRef = undefined;
    }
    this._markDirty();
    this.flush();
  }

  /** Persist messages + model immediately. */
  flush(): void {
    if (!this._sessionDir || !this._sessionId.startsWith("sess_")) return;

    const now = new Date().toISOString();
    const record: SessionRecord = {
      sessionId: this._sessionId,
      sessionName: this._sessionName,
      cwd: this._cwd,
      createdAt: this._createdAt,
      updatedAt: now,
      model: this._savedModelRef,
      messages: this._messages,
    };
    saveSessionRecord(this._sessionDir, record);
    this._dirty = false;
  }

  compactionBackupPath(): string {
    return join(this._sessionDir, this._sessionId, "compaction-backup.json");
  }

  saveCompactionBackup(messages: AgentMessage[]): void {
    if (!this._sessionDir) return;
    const dir = join(this._sessionDir, this._sessionId);
    if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
    writeFileSync(
      this.compactionBackupPath(),
      JSON.stringify({ savedAt: new Date().toISOString(), messages }, null, 2) + "\n",
      "utf-8",
    );
  }

  loadCompactionBackup(): AgentMessage[] | null {
    const path = this.compactionBackupPath();
    if (!existsSync(path)) return null;
    try {
      const parsed = JSON.parse(readFileSync(path, "utf-8")) as {
        messages?: AgentMessage[];
      };
      return Array.isArray(parsed.messages) ? parsed.messages : null;
    } catch {
      return null;
    }
  }

  clearCompactionBackup(): void {
    const path = this.compactionBackupPath();
    if (existsSync(path)) {
      try {
        writeFileSync(path, "", "utf-8");
      } catch {
        /* ignore */
      }
    }
  }

  exportMarkdown(): string {
    const lines: string[] = [
      `# ${this._sessionName}`,
      "",
      `- **Session ID:** ${this._sessionId}`,
      `- **Working directory:** ${this._cwd}`,
      `- **Model:** ${this._savedModelRef ? `${this._savedModelRef.provider}/${this._savedModelRef.id}` : "(none)"}`,
      `- **Messages:** ${this._messages.length}`,
      "",
      "---",
      "",
    ];

    for (const msg of this._messages) {
      const role = msg.role ?? "unknown";
      const content = (msg as { content?: unknown }).content;
      let text = "";
      if (typeof content === "string") {
        text = content;
      } else if (Array.isArray(content)) {
        text = content
          .map((part) => {
            if (typeof part === "string") return part;
            if (part && typeof part === "object" && "text" in part) {
              return String((part as { text?: string }).text ?? "");
            }
            return JSON.stringify(part);
          })
          .join("\n");
      } else if (content != null) {
        text = JSON.stringify(content);
      }
      lines.push(`## ${role}`, "", text, "", "---", "");
    }

    return lines.join("\n");
  }

  dispose(): void {
    this._stopAutoSave();
    this.flush();
  }

  private _markDirty(): void {
    this._dirty = true;
  }

  private _startAutoSave(): void {
    if (!this._autoSave || !this._sessionDir || this._autoSaveTimer) return;
    this._autoSaveTimer = setInterval(() => {
      if (this._dirty) this.flush();
    }, this._saveIntervalMs);
    if (typeof this._autoSaveTimer.unref === "function") {
      this._autoSaveTimer.unref();
    }
  }

  private _stopAutoSave(): void {
    if (this._autoSaveTimer) {
      clearInterval(this._autoSaveTimer);
      this._autoSaveTimer = null;
    }
  }
}
