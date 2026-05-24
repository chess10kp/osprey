// ────────────────────────────────────────────────────────────────────────────
// Event bridge — translates agent session events into store mutations.
//
// Subscribes to session events and normalizes them into the AgentStore
// snapshot. This is the only code that mutates the store after boot.
// ────────────────────────────────────────────────────────────────────────────

import type { AgentStore, AgentMessage as StoreMessage } from "./store.js";
import type { DevMode } from "../agent/dev-mode.js";
import { truncateToolPayload } from "../agent/tool-output-limit.js";
import {
  enrichToolInputFromResult,
  formatToolSummary,
  toolEventInput,
} from "./tool-summary.js";

function toolResultDisplayText(value: unknown): string | undefined {
  if (value === undefined || value === null) return undefined;
  if (typeof value === "string") return value;
  if (typeof value === "object" && value !== null) {
    if ("error" in value) {
      return String((value as { error?: unknown }).error ?? "Tool failed");
    }
    if ("content" in value && Array.isArray((value as { content?: unknown }).content)) {
      const parts = (value as { content: Array<{ type?: string; text?: string }> }).content
        .map((part) => (part?.type === "text" && typeof part.text === "string" ? part.text : ""))
        .filter(Boolean);
      if (parts.length > 0) return parts.join("\n");
    }
  }
  return undefined;
}

function formatToolPayload(value: unknown): string | undefined {
  const display = toolResultDisplayText(value);
  if (display !== undefined) return truncateToolPayload(display);
  return truncateToolPayload(value);
}

function toolResultStatus(value: unknown, isError?: unknown): "done" | "error" {
  if (isError === true) return "error";
  if (value && typeof value === "object" && "error" in value) {
    return "error";
  }
  return "done";
}

function agentMessageToStore(message: {
  role?: string;
  content?: unknown;
}): StoreMessage | null {
  const role = message.role;
  if (role !== "user" && role !== "assistant" && role !== "system") return null;

  const content = message.content;
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

  return { role, text };
}

function agentMessagesToStore(messages: unknown[]): StoreMessage[] {
  const out: StoreMessage[] = [];
  for (const msg of messages) {
    if (!msg || typeof msg !== "object") continue;
    const converted = agentMessageToStore(msg as { role?: string; content?: unknown });
    if (converted) out.push(converted);
  }
  return out;
}

/** Sync store with session state emitted before the bridge subscribed. */
export function seedStoreFromSession(
  store: AgentStore,
  seed: {
    mode: DevMode;
    provider: string;
    model: string;
    sessionId: string;
    sessionName: string;
    messages?: unknown[];
  },
): void {
  store.setMode(seed.mode);
  store.setModel(seed.provider, seed.model);
  store.setSession(seed.sessionId, seed.sessionName);
  if (seed.messages && seed.messages.length > 0) {
    store.setTranscript(agentMessagesToStore(seed.messages));
  }
}

/**
 * Subscribe a store to an agent session event stream.
 * Returns an unsubscribe function.
 */
export function bridgeEvents(
  session: { subscribe: (handler: (event: { type?: string; [key: string]: unknown }) => void) => () => void },
  store: AgentStore,
): () => void {
  const startedAt = new Map<string, number>();

  const handler = (event: { type?: string; [key: string]: unknown }): void => {
    if (!event?.type) return;

    switch (event.type) {
      // ── Session lifecycle ─────────────────────────────────────────
      case "session_start":
        if (event.sessionId) {
          store.setSession(
            String(event.sessionId),
            event.sessionName ? String(event.sessionName) : "",
          );
        }
        if (event.reason === "new") {
          store.clearTranscript();
        } else if (event.reason === "resume" && Array.isArray(event.messages)) {
          store.setTranscript(agentMessagesToStore(event.messages));
        }
        break;

      // ── Agent loop ────────────────────────────────────────────────
      case "agent_start":
        store.setPhase("streaming");
        break;

      case "agent_end":
        // If still streaming, finalize the last message
        if (store.getSnapshot().streamingText !== null) {
          store.finalizeStreaming();
        }
        store.pruneToolExecutions();
        store.setPhase("ready");
        break;

      // ── Messages ──────────────────────────────────────────────────
      case "message_start": {
        const msg = event.message as { role?: string } | undefined;
        if (msg?.role === "assistant" || !msg) {
          store.beginStreaming();
        }
        break;
      }

      case "message_update":
        // Text delta — assistantMessageEvent.delta for text_delta events
        const ame = event.assistantMessageEvent as { type?: string; delta?: string } | undefined;
        if (ame?.type === "text_delta" && ame.delta) {
          store.appendStreamText(String(ame.delta));
        } else if (event.text) {
          store.appendStreamText(String(event.text));
        }
        break;

      case "message_end":
        // Only finalize if we were streaming (assistant message)
        if (store.getSnapshot().streamingText !== null) {
          store.finalizeStreaming();
        }
        break;

      // ── Tool executions ───────────────────────────────────────────
      case "tool_execution_start": {
        if (store.getSnapshot().streamingText !== null) {
          store.finalizeStreaming();
        }
        const toolCallId = String(event.toolCallId ?? "");
        startedAt.set(toolCallId, Date.now());
        const toolName = String(event.toolName ?? "unknown");
        const input = toolEventInput(event);
        store.upsertToolExecution({
          toolCallId,
          toolName,
          status: "running",
          input,
          summary: formatToolSummary(toolName, input),
        });
        break;
      }

      case "tool_execution_end": {
        const toolCallId = String(event.toolCallId ?? "");
        const start = startedAt.get(toolCallId);
        const durationMs = typeof start === "number" ? Date.now() - start : undefined;
        startedAt.delete(toolCallId);
        const toolName = String(event.toolName ?? "unknown");
        const existing = store.getSnapshot().toolExecutions[toolCallId];
        const input = enrichToolInputFromResult(
          toolName,
          toolEventInput(event) ?? existing?.input,
          event.result,
        );
        store.upsertToolExecution({
          toolCallId,
          toolName,
          status: toolResultStatus(event.result, event.isError),
          input,
          summary: formatToolSummary(toolName, input),
          result: formatToolPayload(event.result),
          durationMs,
        });
        break;
      }

      // ── Model ─────────────────────────────────────────────────────
      case "model_select":
        store.setModel(
          event.provider ? String(event.provider) : "",
          event.model ? String(event.model) : "",
        );
        break;

      // ── MCP ───────────────────────────────────────────────────────
      case "mcp_connecting":
        store.setMcpStatus({
          connected: false,
          connecting: true,
          server: event.server ? String(event.server) : "jac",
          toolCount: 0,
          error: null,
        });
        break;

      case "mcp_ready":
        store.setMcpStatus({
          connected: true,
          connecting: false,
          server: event.server ? String(event.server) : "jac",
          toolCount: typeof event.toolCount === "number" ? event.toolCount : undefined,
          error: null,
        });
        break;

      case "mcp_status":
        store.setMcpStatus({
          connected: Boolean(event.connected),
          connecting: false,
          server: event.server ? String(event.server) : undefined,
          toolCount: typeof event.toolCount === "number" ? event.toolCount : undefined,
          error: event.error ? String(event.error) : null,
        });
        break;

      // ── Compaction ────────────────────────────────────────────────
      case "compaction_start":
        store.setPhase("compacting");
        break;

      case "compaction_end":
        store.setPhase("ready");
        if (Array.isArray(event.messages)) {
          store.setTranscript(agentMessagesToStore(event.messages));
        }
        break;

      case "auto_compact": {
        const percentBefore = typeof event.percentBefore === "number" ? event.percentBefore : "?";
        const via = event.strategy === "llm" ? " (LLM summary)" : "";
        store.pushUserMessage(
          `[auto-compact] Compacted ${String(event.dropped ?? 0)} message(s)${via} — context was at ${String(percentBefore)}%.`,
        );
        break;
      }

      // ── Retry ─────────────────────────────────────────────────────
      case "auto_retry_start":
        store.setPhase("retrying");
        break;

      case "auto_retry_end":
        store.setPhase("ready");
        break;

      // ── Development mode ──────────────────────────────────────────
      case "mode_change":
        if (event.mode) {
          store.setMode(String(event.mode) as DevMode);
        }
        break;

      // ── Shutdown ──────────────────────────────────────────────────
      case "session_shutdown":
        store.setPhase("booting");
        break;

      default:
        // Unknown event — ignore silently (forward-compatible).
        break;
    }
  };

  return session.subscribe(handler);
}
