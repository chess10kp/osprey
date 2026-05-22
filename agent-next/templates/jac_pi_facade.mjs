// ────────────────────────────────────────────────────────────────────────────
// @jac/pi facade — interim adapter shim emitted into .jac/tui/.
//
// Bridges shell.cl.jac (Ink) to the headless agent-next adapter
// (agent-next/dist/index.js). Exposes a stable React-hook API that the
// Jac shell uses for state, streaming, auth, dialogs, and actions.
//
// This file overrides the stub jac-ink emits as `jac_pi_runtime_shim.mjs`.
// ────────────────────────────────────────────────────────────────────────────

import { useEffect, useState, useRef, useCallback } from "react";

// Path to the compiled headless adapter. Set by the launcher (jackal.sh) via
// JACKAL_AGENT_DIST. Defaults to <repo>/agent-next/dist/index.js.
const ADAPTER_PATH =
  process.env.JACKAL_AGENT_DIST ||
  new URL(
    "../../agent-next/dist/index.js",
    import.meta.url,
  ).pathname;

// ── Singleton adapter state ────────────────────────────────────────────────

const state = {
  ready: false,
  booting: false,
  error: null,
  adapter: null, // { store, uiContext, authFlow, authActions, actions }
  listeners: new Set(),
  initPromise: null,
};

function emit() {
  for (const fn of state.listeners) {
    try {
      fn();
    } catch {
      /* swallow */
    }
  }
}

async function bootAdapter() {
  if (state.initPromise) return state.initPromise;
  state.booting = true;
  emit();
  state.initPromise = (async () => {
    try {
      const mod = await import(ADAPTER_PATH);
      const cwd = process.env.JACKAL_AGENT_CWD || process.cwd();
      const adapter = await mod.createNextAgent(cwd);

      // Fan-out: any change in store/auth/ui re-emits to all hooks.
      adapter.store.subscribe(emit);
      adapter.authFlow.subscribe(emit);
      adapter.uiContext.subscribe(emit);

      state.adapter = adapter;
      state.ready = true;
      state.booting = false;
      emit();
    } catch (err) {
      state.error = err?.message || String(err);
      state.booting = false;
      emit();
    }
  })();
  return state.initPromise;
}

function subscribe(listener) {
  state.listeners.add(listener);
  return () => {
    state.listeners.delete(listener);
  };
}

// ── React hooks (the @jac/pi developer API) ────────────────────────────────

function useTick() {
  const [, set] = useState(0);
  useEffect(() => subscribe(() => set((v) => v + 1)), []);
}

/** Ensure the adapter is booting on mount. Returns { ready, booting, error }. */
function usePiBoot() {
  useTick();
  useEffect(() => {
    bootAdapter();
  }, []);
  return {
    ready: state.ready,
    booting: state.booting,
    error: state.error,
  };
}

/** Current agent snapshot from the store. */
function useAgentState() {
  useTick();
  return state.adapter ? state.adapter.store.getSnapshot() : null;
}

/** Live streaming text (or null when idle). */
function useAgentStream() {
  const snap = useAgentState();
  return snap?.streamingText ?? null;
}

/** Full message history. */
function useMessages() {
  const snap = useAgentState();
  return snap?.messages ?? [];
}

/** Tool execution timeline (running + done), ordered by insertion. */
function useToolTimeline() {
  const snap = useAgentState();
  if (!snap) return [];
  return Object.values(snap.toolExecutions);
}

/** Auth flow state machine snapshot. */
function useAuthFlow() {
  useTick();
  return state.adapter ? state.adapter.authFlow.state : { step: { kind: "idle" } };
}

/** Headless UI state (notifications, dialogs, working indicator, status). */
function useExtensionUI() {
  useTick();
  return state.adapter
    ? state.adapter.uiContext.getUIState()
    : { notifications: [], dialogs: [], statusEntries: {}, workingMessage: null, workingVisible: false };
}

/** Imperative actions on the Pi session. Stable identity. */
function usePiSession() {
  const actionsRef = useRef(null);
  useTick();
  if (!actionsRef.current && state.adapter) {
    const a = state.adapter;
    actionsRef.current = {
      send: (text) => a.actions.send(text),
      abort: () => a.actions.abort(),
      resolveDialog: (id, value) => a.actions.resolveDialog(id, value),
      setModel: (provider, modelId) => a.actions.setModel(provider, modelId),
      clearSession: () => a.actions.clearSession(),
      dispose: () => a.actions.dispose(),

      // Auth actions
      login: () => a.authActions.login(),
      loginWith: (providerId) => a.authActions.loginWith(providerId),
      logout: (providerId) => a.authActions.logout(providerId),
      cancelLogin: () => a.authActions.cancelLogin(),
      submitAuthPrompt: (value) => a.authActions.submitAuthPrompt(value),
      submitAuthSelect: (id) => a.authActions.submitAuthSelect(id),
      submitApiKey: (key) => a.authActions.submitApiKey(key),
      selectModel: (provider, modelId) => {
        a.authActions.selectModel(provider, modelId);
        return a.actions.setModel(provider, modelId);
      },
      openProviderPicker: () => a.authActions.login(),
      openModelPicker: () => {
        const models = a.authActions.listModels();
        a.authFlow.openModelPicker(models);
      },
      listProviders: () => a.authActions.listProviders(),
      listModels: (provider) => a.authActions.listModels(provider),
    };
  }
  return actionsRef.current;
}

/** Slash-command completion suggestions for the current input. */
function useCompletions(input) {
  useTick();
  const [list, setList] = useState([]);
  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const mod = await import(ADAPTER_PATH);
        if (cancelled) return;
        const a = state.adapter;
        const step = a?.authFlow.state.step ?? { kind: "idle" };
        const providers = a ? a.authActions.listProviders().map((p) => p.id) : [];
        const models = a ? a.authActions.listModels().map((m) => `${m.provider}/${m.modelId}`) : [];
        let authOptions = [];
        if (step.kind === "select") authOptions = step.options.map((o) => o.id);
        const ctx = {
          authStepKind: step.kind,
          providers,
          models,
          authOptions,
        };
        const sugg = mod.getSuggestions(input ?? "", ctx);
        setList(sugg);
      } catch {
        setList([]);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [input]);
  return list;
}

// ── Exports ────────────────────────────────────────────────────────────────

export {
  usePiBoot,
  usePiSession,
  useAgentState,
  useAgentStream,
  useMessages,
  useToolTimeline,
  useAuthFlow,
  useExtensionUI,
  useCompletions,
};
