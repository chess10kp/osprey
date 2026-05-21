// ────────────────────────────────────────────────────────────────────────────
// Adapter — creates a headless Pi AgentSession wired into the AgentStore.
//
// This is the glue between Pi's SDK and Jackal's store/bridge layer.
// It does NOT import pi-tui or any rendering code.
// ────────────────────────────────────────────────────────────────────────────

import {
  createAgentSession,
  SessionManager,
} from "@earendil-works/pi-coding-agent";
import { AgentStore } from "./store.js";
import { bridgeEvents } from "./bridge.js";
import { InkExtensionUIContext } from "./ui-context.js";

export interface NextAgentResult {
  ok: boolean;
  eventTypes: string[];
  snapshotCount: number;
  dialogCount: number;
  error?: string;
}

/**
 * Phase-0 smoke: boot a headless Pi session, run one prompt turn,
 * and verify the store + bridge + UI context work end-to-end.
 */
export async function runNextAgentSmoke(cwd: string): Promise<NextAgentResult> {
  const store = new AgentStore();
  const uiContext = new InkExtensionUIContext(store);
  const eventTypes = new Set<string>();

  let snapshotCount = 0;
  const unsubStore = store.subscribe(() => {
    snapshotCount++;
  });

  let uiMutations = 0;
  const unsubUI = uiContext.subscribe(() => {
    uiMutations++;
  });

  try {
    const { session } = await createAgentSession({
      cwd,
      sessionManager: SessionManager.inMemory(cwd),
      noTools: "all",
    });

    // Bind the headless UI context so extensions can call notify/select/etc.
    await session.bindExtensions({
      uiContext: uiContext as any,
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
    unsubUI();

    return {
      ok: true,
      eventTypes: [...eventTypes],
      snapshotCount,
      dialogCount: uiMutations,
    };
  } catch (err: any) {
    unsubStore();
    unsubUI();
    return {
      ok: false,
      eventTypes: [...eventTypes],
      snapshotCount,
      dialogCount: uiMutations,
      error: err?.message || String(err),
    };
  }
}

/**
 * Create a full adapter: Pi session wired into an AgentStore + UI context.
 * Returns the store, UI context, and imperative actions for the Ink layer.
 */
export async function createNextAgent(cwd: string): Promise<{
  store: AgentStore;
  uiContext: InkExtensionUIContext;
  actions: {
    send: (text: string) => Promise<void>;
    resolveDialog: (id: string, value: any) => void;
    dispose: () => void;
  };
}> {
  const store = new AgentStore();
  const uiContext = new InkExtensionUIContext(store);

  const { session } = await createAgentSession({
    cwd,
    sessionManager: SessionManager.inMemory(cwd),
  });

  await session.bindExtensions({
    uiContext: uiContext as any,
  });

  const unsubBridge = bridgeEvents(session, store);
  store.markReady();

  return {
    store,
    uiContext,
    actions: {
      send: async (text: string) => {
        store.pushUserMessage(text);
        await session.sendUserMessage(text);
      },
      resolveDialog: (id: string, value: any) => {
        uiContext.resolveDialog(id, value);
      },
      dispose: () => {
        unsubBridge();
        session.dispose();
        store.reset();
      },
    },
  };
}
