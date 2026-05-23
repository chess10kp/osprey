// ────────────────────────────────────────────────────────────────────────────
// Event bridge — translates agent session events into store mutations.
//
// Subscribes to session events and normalizes them into the AgentStore
// snapshot. This is the only code that mutates the store after boot.
// ────────────────────────────────────────────────────────────────────────────

import type { AgentStore } from "./store.js";

function formatToolPayload(value: unknown): string | undefined {
  if (value === undefined || value === null) return undefined;
  if (typeof value === "string") return value;
  try {
    return JSON.stringify(value);
  } catch {
    return String(value);
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
        const toolCallId = String(event.toolCallId ?? "");
        startedAt.set(toolCallId, Date.now());
        store.upsertToolExecution({
          toolCallId,
          toolName: String(event.toolName ?? "unknown"),
          status: "running",
          input: event.input as Record<string, unknown> | undefined,
        });
        break;
      }

      case "tool_execution_end": {
        const toolCallId = String(event.toolCallId ?? "");
        const start = startedAt.get(toolCallId);
        const durationMs = typeof start === "number" ? Date.now() - start : undefined;
        startedAt.delete(toolCallId);
        store.upsertToolExecution({
          toolCallId,
          toolName: String(event.toolName ?? "unknown"),
          status: "done",
          input: event.input as Record<string, unknown> | undefined,
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

      // ── Compaction ────────────────────────────────────────────────
      case "compaction_start":
        store.setPhase("compacting");
        break;

      case "compaction_end":
        store.setPhase("ready");
        break;

      // ── Retry ─────────────────────────────────────────────────────
      case "auto_retry_start":
        store.setPhase("retrying");
        break;

      case "auto_retry_end":
        store.setPhase("ready");
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
