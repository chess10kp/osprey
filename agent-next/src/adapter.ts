// ────────────────────────────────────────────────────────────────────────────
// Adapter — creates a headless Pi AgentSession wired into the AgentStore.
//
// This is the glue between Pi's SDK and Jackal's store/bridge layer.
// It does NOT import pi-tui or any rendering code.
// ────────────────────────────────────────────────────────────────────────────

import { createAgentSession, SessionManager } from "@earendil-works/pi-coding-agent";
import { AgentStore } from "./store.js";
import { bridgeEvents } from "./bridge.js";

export interface NextAgentResult {
  ok: boolean;
  eventTypes: string[];
  snapshotCount: number;
  error?: string;
}

/**
 * Phase-0 smoke: boot a headless Pi session, run one prompt turn,
 * and verify the store + bridge work end-to-end.
 */
export async function runNextAgentSmoke(cwd: string): Promise<NextAgentResult> {
  const store = new AgentStore();
  const eventTypes = new Set<string>();

  // Track all snapshot changes
  let snapshotCount = 0;
  const unsubStore = store.subscribe(() => {
    snapshotCount++;
  });

  try {
    const { session } = await createAgentSession({
      cwd,
      sessionManager: SessionManager.inMemory(cwd),
      noTools: "all",
    });

    const unsubEvents = session.subscribe((event: any) => {
      if (event?.type) eventTypes.add(String(event.type));
    });

    const unsubBridge = bridgeEvents(session, store);

    try {
      await session.sendUserMessage("Respond with exactly: headless-ok");
    } finally {
      unsubEvents();
      unsubBridge();
      session.dispose();
    }

    unsubStore();

    return {
      ok: true,
      eventTypes: [...eventTypes],
      snapshotCount,
    };
  } catch (err: any) {
    unsubStore();
    return {
      ok: false,
      eventTypes: [...eventTypes],
      snapshotCount,
      error: err?.message || String(err),
    };
  }
}

/**
 * Create a full adapter: Pi session wired into an AgentStore.
 * Returns the store + imperative actions for the UI layer.
 */
export async function createNextAgent(cwd: string): Promise<{
  store: AgentStore;
  actions: {
    send: (text: string) => Promise<void>;
    dispose: () => void;
  };
}> {
  const store = new AgentStore();

  const { session } = await createAgentSession({
    cwd,
    sessionManager: SessionManager.inMemory(cwd),
  });

  const unsubBridge = bridgeEvents(session, store);
  store.markReady();

  return {
    store,
    actions: {
      send: async (text: string) => {
        store.pushUserMessage(text);
        await session.sendUserMessage(text);
      },
      dispose: () => {
        unsubBridge();
        session.dispose();
        store.reset();
      },
    },
  };
}
