// Adapter — Jackal agent runtime wired into the AgentStore.

import { AgentStore } from "./store.js";
import { bridgeEvents } from "./bridge.js";
import { JackalUIContext } from "./ui-context.js";
import { AuthFlowStore } from "./auth-flow.js";
import { AuthActions } from "./auth-actions.js";
import { JackalAuth, JackalModels } from "./runtime/auth.js";
import { JackalSessionManager } from "./runtime/session.js";
import { JackalAgentSession } from "./runtime/agent-session.js";

export interface NextAgentResult {
  ok: boolean;
  eventTypes: string[];
  snapshotCount: number;
  dialogCount: number;
  error?: string;
}

export interface CreateNextAgentOptions {
  authPath?: string;
  sessionDir?: string;
}

/**
 * Phase-0 smoke: boot a headless Jackal session, run one prompt turn,
 * and verify the store + bridge + UI context work end-to-end.
 */
export async function runNextAgentSmoke(cwd: string): Promise<NextAgentResult> {
  const store = new AgentStore();
  const uiContext = new JackalUIContext(store);
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
    const auth = JackalAuth.create();
    const models = new JackalModels(auth);
    const sessionManager = JackalSessionManager.inMemory(cwd);
    const session = new JackalAgentSession({
      cwd,
      auth,
      models,
      sessionManager,
    });

    const unsubEvents = session.subscribe((event) => {
      if (event?.type) eventTypes.add(String(event.type));
    });
    const unsubBridge = bridgeEvents(session, store);
    await session.initialize();

    try {
      await session.sendUserMessage("Respond with exactly: headless-ok");
      await new Promise((r) => setTimeout(r, 1500));
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
  } catch (err: unknown) {
    unsubStore();
    unsubUI();
    const message = err instanceof Error ? err.message : String(err);
    return {
      ok: false,
      eventTypes: [...eventTypes],
      snapshotCount,
      dialogCount: uiMutations,
      error: message,
    };
  }
}

/**
 * Create a full adapter: Jackal session wired into store + auth + UI context.
 */
export async function createNextAgent(
  cwd: string,
  options?: CreateNextAgentOptions,
): Promise<{
  store: AgentStore;
  uiContext: JackalUIContext;
  authFlow: AuthFlowStore;
  authActions: AuthActions;
  actions: {
    send: (text: string) => Promise<void>;
    abort: () => Promise<void>;
    resolveDialog: (id: string, value: unknown) => void;
    setModel: (provider: string, modelId: string) => Promise<void>;
    clearSession: () => Promise<void>;
    compactSession: () => Promise<{ compacted: boolean; dropped: number }>;
    runTool: (name: string, params?: Record<string, unknown>) => Promise<string>;
    runFixFlow: (maxAttempts?: number) => Promise<string>;
    dispose: () => void;
  };
}> {
  const store = new AgentStore();
  const uiContext = new JackalUIContext(store);
  const authFlow = new AuthFlowStore();

  const auth = JackalAuth.create(options?.authPath);
  const models = new JackalModels(auth);
  const authActions = new AuthActions(auth, models, authFlow);

  const sessionManager = JackalSessionManager.continueRecent(cwd, options?.sessionDir);

  const session = new JackalAgentSession({
    cwd,
    auth,
    models,
    sessionManager,
  });

  const unsubBridge = bridgeEvents(session, store);
  await session.initialize();
  store.markReady();

  return {
    store,
    uiContext,
    authFlow,
    authActions,
    actions: {
      send: async (text: string) => {
        store.pushUserMessage(text);
        await session.sendUserMessage(text);
      },
      abort: async () => {
        await session.abort();
      },
      resolveDialog: (id: string, value: unknown) => {
        uiContext.resolveDialog(id, value);
      },
      setModel: async (provider: string, modelId: string) => {
        const model = models.find(provider, modelId);
        if (model) {
          await session.setModel(model);
        }
        authFlow.setIdle();
      },
      clearSession: async () => {
        session.resetForNewSession();
      },
      compactSession: async () => {
        return session.compactContext();
      },
      runTool: async (name: string, params?: Record<string, unknown>) => {
        return session.runTool(name, params ?? {});
      },
      runFixFlow: async (maxAttempts?: number) => {
        return session.runFixFlow(maxAttempts ?? 3);
      },
      dispose: () => {
        unsubBridge();
        session.dispose();
        store.reset();
        authFlow.reset();
      },
    },
  };
}
