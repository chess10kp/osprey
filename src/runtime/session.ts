// Lightweight session persistence for the Jackal agent runtime.

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { AgentMessage } from "@earendil-works/pi-agent-core";
import type { Model, Api } from "@earendil-works/pi-ai";

export interface SessionSnapshot {
  sessionId: string;
  sessionName: string;
  model?: { provider: string; id: string };
  messages: AgentMessage[];
}

export class JackalSessionManager {
  private _cwd: string;
  private _sessionDir: string;
  private _sessionId: string;
  private _sessionName: string;
  private _messages: AgentMessage[] = [];
  private _model?: Model<Api>;

  private constructor(
    cwd: string,
    sessionDir: string,
    sessionId: string,
    sessionName: string,
  ) {
    this._cwd = cwd;
    this._sessionDir = sessionDir;
    this._sessionId = sessionId;
    this._sessionName = sessionName;
  }

  static continueRecent(cwd: string, sessionDir?: string): JackalSessionManager {
    const dir = sessionDir ?? join(cwd, ".jackal", "sessions");
    const mgr = new JackalSessionManager(
      cwd,
      dir,
      `sess_${Date.now()}`,
      "session",
    );
    const loaded = mgr._loadLatest();
    if (loaded) {
      mgr._sessionId = loaded.sessionId;
      mgr._sessionName = loaded.sessionName;
      mgr._messages = loaded.messages;
    }
    return mgr;
  }

  static inMemory(cwd?: string): JackalSessionManager {
    return new JackalSessionManager(
      cwd ?? process.cwd(),
      "",
      `mem_${Date.now()}`,
      "memory",
    );
  }

  get cwd(): string {
    return this._cwd;
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

  setModel(model: Model<Api>): void {
    this._model = model;
    this._persist();
  }

  setMessages(messages: AgentMessage[]): void {
    this._messages = messages;
    this._persist();
  }

  newSession(): void {
    this._sessionId = `sess_${Date.now()}`;
    this._sessionName = "new session";
    this._messages = [];
    this._persist();
  }

  private _sessionFile(): string {
    return join(this._sessionDir, "latest.json");
  }

  private _loadLatest(): SessionSnapshot | null {
    const path = this._sessionFile();
    if (!existsSync(path)) return null;
    try {
      return JSON.parse(readFileSync(path, "utf-8")) as SessionSnapshot;
    } catch {
      return null;
    }
  }

  private _persist(): void {
    if (!this._sessionDir) return;
    if (!existsSync(this._sessionDir)) {
      mkdirSync(this._sessionDir, { recursive: true });
    }
    const snap: SessionSnapshot = {
      sessionId: this._sessionId,
      sessionName: this._sessionName,
      model: this._model
        ? { provider: this._model.provider, id: this._model.id }
        : undefined,
      messages: this._messages,
    };
    writeFileSync(this._sessionFile(), JSON.stringify(snap, null, 2) + "\n", "utf-8");
  }
}
