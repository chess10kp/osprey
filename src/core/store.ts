// ────────────────────────────────────────────────────────────────────────────
// Agent store — immutable snapshot store backed by useSyncExternalStore.
//
// The store is the single source of truth for agent state. Session events
// are translated into store mutations by the event bridge (bridge.ts).
// Consumers (Ink components, runtime hooks) subscribe and get immutable snapshots.
// ────────────────────────────────────────────────────────────────────────────

import type { DevMode } from "../agent/dev-mode.js";
import type { PendingApproval } from "../agent/tool-approval.js";
import type { PendingSubagentApproval } from "../agent/subagent-approval.js";
import { truncateToolOutput } from "../agent/tool-output-limit.js";

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
  status: "running" | "done" | "error";
  input?: Record<string, unknown>;
  /** Precomputed one-line label for compact tool rows in the TUI. */
  summary?: string;
  result?: string;
  durationMs?: number;
}

export interface ToolTranscriptEntry {
  kind: "tool";
  toolCallId: string;
  toolName: string;
  status: "running" | "done" | "error";
  input?: Record<string, unknown>;
  summary?: string;
  result?: string;
  durationMs?: number;
}

export type TranscriptEntry =
  | { kind: "user"; text: string }
  | { kind: "assistant"; text: string }
  | { kind: "system"; text: string }
  | ToolTranscriptEntry;

export interface AgentMessage {
  role: "user" | "assistant" | "system";
  text: string;
  toolCalls?: ToolExecution[];
}

/** Map legacy chat messages to transcript entries (no tool rows). */
export function agentMessagesToTranscript(messages: AgentMessage[]): TranscriptEntry[] {
  return messages.map((message) => ({
    kind: message.role,
    text: message.text,
  }));
}

export interface AgentSnapshot {
  phase: AgentPhase;
  mode: DevMode;
  pendingApproval: PendingApproval | null;
  pendingSubagentApproval: PendingSubagentApproval | null;
  model: string;
  provider: string;
  sessionId: string;
  sessionName: string;
  mcpConnected: boolean;
  mcpConnecting: boolean;
  mcpServer: string;
  mcpToolCount: number;
  mcpError: string | null;
  /** Chat-only view for legacy UI; canonical order is `transcript`. */
  messages: AgentMessage[];
  /** Ordered transcript: user, assistant, and tool rows. */
  transcript: TranscriptEntry[];
  /** Bumps when transcript is cleared or replaced (Ink Static remount). */
  transcriptEpoch: number;
  /** In-flight assistant message text (null when idle). */
  streamingText: string | null;
  /** Running tool id for live transcript slot (PR2 UI). */
  liveToolCallId: string | null;
  toolExecutions: Record<string, ToolExecution>;
  tokens: { in: number; out: number } | null;
  cost: number | null;
  error: string | null;
}

const INITIAL_SNAPSHOT: AgentSnapshot = {
  phase: "booting",
  mode: "normal",
  pendingApproval: null,
  pendingSubagentApproval: null,
  model: "",
  provider: "",
  sessionId: "",
  sessionName: "",
  mcpConnected: false,
  mcpConnecting: false,
  mcpServer: "",
  mcpToolCount: 0,
  mcpError: null,
  messages: [],
  transcript: [],
  transcriptEpoch: 0,
  streamingText: null,
  liveToolCallId: null,
  toolExecutions: {},
  tokens: null,
  cost: null,
  error: null,
};

export type Listener = () => void;

/** Keep only the most recent tool executions in the store. */
export const MAX_TOOL_EXECUTIONS = 40;
/** Throttle streaming UI updates to reduce re-render churn (~30 fps). */
export const STREAM_EMIT_MS = 32;

export class AgentStore {
  private _snapshot: AgentSnapshot = { ...INITIAL_SNAPSHOT };
  private _listeners = new Set<Listener>();
  private _streamEmitTimer: ReturnType<typeof setTimeout> | null = null;

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

  setMode(mode: DevMode): void {
    this._patch({ mode });
  }

  setPendingApproval(pendingApproval: PendingApproval | null): void {
    this._patch({ pendingApproval });
  }

  setPendingSubagentApproval(pendingSubagentApproval: PendingSubagentApproval | null): void {
    this._patch({ pendingSubagentApproval });
  }

  setMcpStatus(status: {
    connected: boolean;
    connecting?: boolean;
    server?: string;
    toolCount?: number;
    error?: string | null;
  }): void {
    this._patch({
      mcpConnected: status.connected,
      mcpConnecting: status.connecting ?? false,
      mcpServer: status.server ?? this._snapshot.mcpServer,
      mcpToolCount: status.toolCount ?? this._snapshot.mcpToolCount,
      mcpError: status.error ?? null,
    });
  }

  /** Start a new streaming assistant message. */
  beginStreaming(): void {
    this._patch({ phase: "streaming", streamingText: "" });
  }

  /** Append text delta to the current streaming message. */
  appendStreamText(delta: string): void {
    const current = this._snapshot.streamingText ?? "";
    this._snapshot = { ...this._snapshot, streamingText: current + delta };
    this._scheduleStreamEmit();
  }

  /** Finalize the streaming message into the messages list. */
  finalizeStreaming(): void {
    this._flushStreamEmit();
    const text = this._snapshot.streamingText ?? "";
    if (!text) {
      this._patch({ phase: "ready", streamingText: null });
      return;
    }
    const messages = [...this._snapshot.messages, { role: "assistant" as const, text }];
    const transcript = [...this._snapshot.transcript, { kind: "assistant" as const, text }];
    this._patch({ phase: "ready", streamingText: null, messages, transcript });
  }

  /** Add a user message to the transcript. */
  pushUserMessage(text: string): void {
    const messages = [...this._snapshot.messages, { role: "user" as const, text }];
    const transcript = [...this._snapshot.transcript, { kind: "user" as const, text }];
    this._patch({ messages, transcript });
  }

  /** Upsert a tool execution and mirror it into the ordered transcript. */
  upsertToolExecution(exec: ToolExecution): void {
    const existing = this._snapshot.toolExecutions[exec.toolCallId];
    const trimmed: ToolExecution = {
      ...existing,
      ...exec,
      input: exec.input ?? existing?.input,
      summary: exec.summary ?? existing?.summary,
      result:
        exec.result !== undefined
          ? exec.result != null
            ? truncateToolOutput(exec.result)
            : undefined
          : existing?.result,
    };
    let toolExecutions = {
      ...this._snapshot.toolExecutions,
      [trimmed.toolCallId]: trimmed,
    };
    toolExecutions = this._pruneToolExecutions(toolExecutions);

    const transcript = [...this._snapshot.transcript];
    const toolEntry: ToolTranscriptEntry = {
      kind: "tool",
      toolCallId: trimmed.toolCallId,
      toolName: trimmed.toolName,
      status: trimmed.status,
      input: trimmed.input,
      summary: trimmed.summary,
      result: trimmed.result,
      durationMs: trimmed.durationMs,
    };

    const index = transcript.findIndex(
      (entry) => entry.kind === "tool" && entry.toolCallId === trimmed.toolCallId,
    );
    if (index >= 0) {
      transcript[index] = toolEntry;
    } else if (trimmed.status === "running") {
      transcript.push(toolEntry);
    }

    const keptIds = new Set(Object.keys(toolExecutions));
    const prunedTranscript = transcript.filter(
      (entry) => entry.kind !== "tool" || keptIds.has(entry.toolCallId),
    );

    let liveToolCallId = this._snapshot.liveToolCallId;
    if (trimmed.status === "running") {
      liveToolCallId = trimmed.toolCallId;
    } else if (liveToolCallId === trimmed.toolCallId) {
      liveToolCallId = null;
    }

    this._patch({
      toolExecutions,
      transcript: prunedTranscript,
      liveToolCallId,
    });
  }

  /** Drop oldest tool rows after each agent turn to cap heap growth. */
  pruneToolExecutions(maxKeep = MAX_TOOL_EXECUTIONS): void {
    const toolExecutions = this._pruneToolExecutions(this._snapshot.toolExecutions, maxKeep);
    if (toolExecutions === this._snapshot.toolExecutions) return;

    const keptIds = new Set(Object.keys(toolExecutions));
    const transcript = this._snapshot.transcript.filter(
      (entry) => entry.kind !== "tool" || keptIds.has(entry.toolCallId),
    );
    const liveToolCallId =
      this._snapshot.liveToolCallId && keptIds.has(this._snapshot.liveToolCallId)
        ? this._snapshot.liveToolCallId
        : null;

    this._patch({ toolExecutions, transcript, liveToolCallId });
  }

  /** Mark the store as ready (boot complete). */
  markReady(): void {
    this._patch({ phase: "ready" });
  }

  /** Clear transcript and tool state but keep model/session metadata. */
  clearTranscript(): void {
    this._patch({
      messages: [],
      transcript: [],
      streamingText: null,
      liveToolCallId: null,
      toolExecutions: {},
      phase: "ready",
      error: null,
      transcriptEpoch: this._snapshot.transcriptEpoch + 1,
    });
  }

  /** Replace transcript (e.g. after /resume). */
  setTranscript(messages: AgentMessage[]): void {
    this._patch({
      messages: [...messages],
      transcript: agentMessagesToTranscript(messages),
      streamingText: null,
      liveToolCallId: null,
      toolExecutions: {},
      phase: "ready",
      error: null,
      transcriptEpoch: this._snapshot.transcriptEpoch + 1,
    });
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

  private _scheduleStreamEmit(): void {
    if (this._streamEmitTimer) return;
    this._streamEmitTimer = setTimeout(() => {
      this._streamEmitTimer = null;
      this._emit();
    }, STREAM_EMIT_MS);
  }

  private _flushStreamEmit(): void {
    if (this._streamEmitTimer) {
      clearTimeout(this._streamEmitTimer);
      this._streamEmitTimer = null;
    }
    this._emit();
  }

  private _pruneToolExecutions(
    toolExecutions: Record<string, ToolExecution>,
    maxKeep = MAX_TOOL_EXECUTIONS,
  ): Record<string, ToolExecution> {
    const ids = Object.keys(toolExecutions);
    if (ids.length <= maxKeep) return toolExecutions;
    const next: Record<string, ToolExecution> = {};
    for (const id of ids.slice(ids.length - maxKeep)) {
      next[id] = toolExecutions[id]!;
    }
    return next;
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
