// ────────────────────────────────────────────────────────────────────────────
// @jac/pi runtime facade — Jackal agent hooks (not pi-coding-agent).
//
// Bridges shell.cl.jac (Ink) to agent-next/dist/index.js (pi-agent-core loop).
// Copied into .jac/tui/jac_pi_runtime_shim.mjs by jackal.sh at launch.
// ────────────────────────────────────────────────────────────────────────────

import { useEffect, useState, useRef } from "react";

const ADAPTER_PATH =
  process.env.JACKAL_AGENT_DIST ||
  new URL("../../agent-next/dist/index.js", import.meta.url).pathname;

let __fileListCache = { at: 0, cwd: "", files: [] };

async function listProjectFiles(cwd) {
  const now = Date.now();
  if (
    __fileListCache.cwd === cwd &&
    now - __fileListCache.at < 5000 &&
    Array.isArray(__fileListCache.files)
  ) {
    return __fileListCache.files;
  }

  const fs = await import("node:fs/promises");
  const path = await import("node:path");
  const out = [];
  const skip = new Set([".git", "node_modules", ".jac", "dist", "build"]);

  async function walk(dir, depth) {
    if (depth > 6 || out.length > 3000) return;
    let entries = [];
    try {
      entries = await fs.readdir(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const e of entries) {
      if (skip.has(e.name)) continue;
      const abs = path.join(dir, e.name);
      if (e.isDirectory()) {
        await walk(abs, depth + 1);
      } else if (e.isFile()) {
        const rel = path.relative(cwd, abs).split(path.sep).join("/");
        out.push(rel);
      }
      if (out.length > 3000) break;
    }
  }

  await walk(cwd, 0);
  __fileListCache = { at: now, cwd, files: out };
  return out;
}

const state = {
  ready: false,
  booting: false,
  error: null,
  adapter: null,
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

function useTick() {
  const [, set] = useState(0);
  useEffect(() => subscribe(() => set((v) => v + 1)), []);
}

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

function useAgentState() {
  useTick();
  return state.adapter ? state.adapter.store.getSnapshot() : null;
}

function useAgentStream() {
  const snap = useAgentState();
  return snap?.streamingText ?? null;
}

function useMessages() {
  const snap = useAgentState();
  return snap?.messages ?? [];
}

function useToolTimeline() {
  const snap = useAgentState();
  if (!snap) return [];
  return Object.values(snap.toolExecutions);
}

function useAuthFlow() {
  useTick();
  return state.adapter ? state.adapter.authFlow.state : { step: { kind: "idle" } };
}

function useExtensionUI() {
  useTick();
  return state.adapter
    ? state.adapter.uiContext.getUIState()
    : {
        notifications: [],
        dialogs: [],
        statusEntries: {},
        workingMessage: null,
        workingVisible: false,
      };
}

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
        const models = a
          ? a.authActions.listModels().map((m) => `${m.provider}/${m.modelId}`)
          : [];
        let authOptions = [];
        if (step.kind === "select") authOptions = step.options.map((o) => o.id);
        const filePaths = await listProjectFiles(process.cwd());
        const ctx = {
          authStepKind: step.kind,
          providers,
          models,
          authOptions,
          filePaths,
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
