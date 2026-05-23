// ────────────────────────────────────────────────────────────────────────────
// Agent store — immutable snapshot store backed by useSyncExternalStore.
//
// The store is the single source of truth for agent state. Session events
// are translated into store mutations by the event bridge (bridge.ts).
// Consumers (Ink components, runtime hooks) subscribe and get immutable snapshots.
// ────────────────────────────────────────────────────────────────────────────

export type AgentPhase =
  | "booting"
  | "ready"
  | "streaming"
  | "compacting"
  | "retrying"
  | "error";

export interface ToolExecution {
  toolCallId: string;
  toolName: string;
  status: "running" | "done";
  input?: Record<string, unknown>;
  result?: string;
}

export interface AgentMessage {
  role: "user" | "assistant" | "system";
  text: string;
  toolCalls?: ToolExecution[];
}

export interface AgentSnapshot {
  phase: AgentPhase;
  model: string;
  provider: string;
  sessionId: string;
  sessionName: string;
  messages: AgentMessage[];
  /** In-flight assistant message text (null when idle). */
  streamingText: string | null;
  toolExecutions: Record<string, ToolExecution>;
  tokens: { in: number; out: number } | null;
  cost: number | null;
  error: string | null;
}

const INITIAL_SNAPSHOT: AgentSnapshot = {
  phase: "booting",
  model: "",
  provider: "",
  sessionId: "",
  sessionName: "",
  messages: [],
  streamingText: null,
  toolExecutions: {},
  tokens: null,
  cost: null,
  error: null,
};

export type Listener = () => void;

export class AgentStore {
  private _snapshot: AgentSnapshot = { ...INITIAL_SNAPSHOT };
  private _listeners = new Set<Listener>();

  /** Get current immutable snapshot. */
  getSnapshot(): AgentSnapshot {
    return this._snapshot;
  }

  /** Subscribe to snapshot changes. Returns unsubscribe function. */
  subscribe(listener: Listener): () => void {
    this._listeners.add(listener);
    return () => {
      this._listeners.delete(listener);
    };
  }

  // ── Mutations (called only by the event bridge) ────────────────────

  setPhase(phase: AgentPhase): void {
    this._patch({ phase });
  }

  setSession(sessionId: string, sessionName: string): void {
    this._patch({ sessionId, sessionName });
  }

  setModel(provider: string, model: string): void {
    this._patch({ provider, model });
  }

  setError(error: string | null): void {
    this._patch({ error, phase: error ? "error" : "ready" });
  }

  /** Start a new streaming assistant message. */
  beginStreaming(): void {
    this._patch({ phase: "streaming", streamingText: "" });
  }

  /** Append text delta to the current streaming message. */
  appendStreamText(delta: string): void {
    const current = this._snapshot.streamingText ?? "";
    // Mutate directly for perf (listeners see final snapshot)
    this._snapshot = { ...this._snapshot, streamingText: current + delta };
    this._emit();
  }

  /** Finalize the streaming message into the messages list. */
  finalizeStreaming(): void {
    const text = this._snapshot.streamingText ?? "";
    const messages = [...this._snapshot.messages, { role: "assistant" as const, text }];
    this._patch({ phase: "ready", streamingText: null, messages });
  }

  /** Add a user message to the transcript. */
  pushUserMessage(text: string): void {
    const messages = [...this._snapshot.messages, { role: "user" as const, text }];
    this._patch({ messages });
  }

  /** Upsert a tool execution. */
  upsertToolExecution(exec: ToolExecution): void {
    const toolExecutions = { ...this._snapshot.toolExecutions, [exec.toolCallId]: exec };
    this._patch({ toolExecutions });
  }

  /** Mark the store as ready (boot complete). */
  markReady(): void {
    this._patch({ phase: "ready" });
  }

  /** Reset to initial state. */
  reset(): void {
    this._snapshot = { ...INITIAL_SNAPSHOT };
    this._emit();
  }

  // ── Internals ──────────────────────────────────────────────────────

  private _patch(partial: Partial<AgentSnapshot>): void {
    this._snapshot = { ...this._snapshot, ...partial };
    this._emit();
  }

  private _emit(): void {
    for (const listener of this._listeners) {
      try {
        listener();
      } catch {
        // swallow — listener errors must not break the store
      }
    }
  }
}
