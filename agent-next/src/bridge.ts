// ────────────────────────────────────────────────────────────────────────────
// Event bridge — translates Pi AgentSession events into store mutations.
//
// Subscribes to session events and normalizes them into the AgentStore
// snapshot. This is the only code that mutates the store after boot.
// ────────────────────────────────────────────────────────────────────────────

import type { AgentStore } from "./store.js";

/**
 * Subscribe a store to a Pi AgentSession event stream.
 * Returns an unsubscribe function.
 */
export function bridgeEvents(
  session: { subscribe: (handler: (event: any) => void) => () => void },
  store: AgentStore,
): () => void {
  const handler = (event: any): void => {
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
      case "message_start":
        store.beginStreaming();
        break;

      case "message_update":
        // Text delta
        if (event.text) {
          store.appendStreamText(String(event.text));
        }
        break;

      case "message_end":
        store.finalizeStreaming();
        break;

      // ── Tool executions ───────────────────────────────────────────
      case "tool_execution_start":
        store.upsertToolExecution({
          toolCallId: String(event.toolCallId ?? ""),
          toolName: String(event.toolName ?? "unknown"),
          status: "running",
          input: event.input,
        });
        break;

      case "tool_execution_end":
        store.upsertToolExecution({
          toolCallId: String(event.toolCallId ?? ""),
          toolName: String(event.toolName ?? "unknown"),
          status: "done",
          result: event.result ? String(event.result) : undefined,
        });
        break;

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
        // Unknown event — ignore silently.
        // This keeps the bridge forward-compatible with new Pi versions.
        break;
    }
  };

  return session.subscribe(handler);
}
