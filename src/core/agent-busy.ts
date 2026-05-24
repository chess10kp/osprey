import type { AgentSnapshot } from "./store.js";

/** True when the agent loop, compaction, retry, or a tool is in flight. */
export function isAgentBusy(snap: AgentSnapshot): boolean {
  if (
    snap.phase === "streaming" ||
    snap.phase === "compacting" ||
    snap.phase === "retrying"
  ) {
    return true;
  }
  if (snap.liveToolCallId) return true;
  return Object.values(snap.toolExecutions).some((t) => t.status === "running");
}
