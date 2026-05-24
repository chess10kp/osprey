// ────────────────────────────────────────────────────────────────────────────
// @jac/pi runtime facade — Jackal React hooks for the Ink shell.
//
// Bridges shell.cl.jac to dist/index.js (pi-agent-core loop).
// Copied into .jac/tui/jac_pi_runtime_shim.mjs by jackal.sh at launch.
// ────────────────────────────────────────────────────────────────────────────

import { useEffect, useState, useRef } from "react";

// ── SIGINT guard ─────────────────────────────────────────────────────────────
// Ink handles the first Ctrl+C via exitOnCtrlC, but a second press during
// teardown can throw. This guard ensures repeated Ctrl+C always exits cleanly.
let __sigintReceived = false;
process.on("SIGINT", () => {
  if (__sigintReceived) {
    process.exit(0);
  }
  __sigintReceived = true;
});

const ADAPTER_PATH =
  process.env.JACKAL_AGENT_DIST ||
  new URL("../../dist/index.js", import.meta.url).pathname;

let __fileListCache = { at: 0, cwd: "", files: [] };

const explorerState = {
  active: false,
  files: [],
  selected: new Set(),
  index: 0,
  filter: "",
  tokenHint: "",
  loading: false,
  error: null,
};

async function listProjectFiles(cwd) {
  const now = Date.now();
  if (
    __fileListCache.cwd === cwd &&
    now - __fileListCache.at < 5000 &&
    Array.isArray(__fileListCache.files)
  ) {
    return __fileListCache.files;
  }

  try {
    const mod = await import(ADAPTER_PATH);
    if (typeof mod.listProjectFiles === "function") {
      const files = await mod.listProjectFiles(cwd);
      __fileListCache = { at: now, cwd, files };
      return files;
    }
  } catch {
    /* fall through to local walk */
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

function filteredExplorerFiles() {
  const q = explorerState.filter.trim().toLowerCase();
  if (!q) return explorerState.files;
  return explorerState.files.filter(
    (f) => f.toLowerCase().includes(q) || f.split("/").pop()?.toLowerCase().includes(q),
  );
}

async function refreshExplorerTokenHint() {
  const paths = [...explorerState.selected];
  if (paths.length === 0) {
    explorerState.tokenHint = "";
    emit();
    return;
  }
  try {
    const mod = await import(ADAPTER_PATH);
    const a = state.adapter;
    if (a?.actions?.estimateFileSelection) {
      const est = await a.actions.estimateFileSelection(paths);
      explorerState.tokenHint = est.warn
        ? `~${est.tokens.toLocaleString()} tokens (large selection)`
        : `~${est.tokens.toLocaleString()} tokens`;
    } else {
      explorerState.tokenHint = `${paths.length} file(s) selected`;
    }
  } catch {
    explorerState.tokenHint = `${paths.length} file(s) selected`;
  }
  emit();
}

const state = {
  ready: false,
  booting: false,
  error: null,
  adapter: null,
  listeners: new Set(),
  initPromise: null,
  screenEpoch: 0,
};

async function forceInkRedraw() {
  const ink = globalThis.__JACKAL_INK;
  const root = globalThis.__JACKAL_INK_ROOT;
  if (!ink?.rerender || !root) return;
  ink.rerender(root);
  if (typeof ink.waitUntilRenderFlush === "function") {
    await ink.waitUntilRenderFlush();
  }
}

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
      const envMode = process.env.JACKAL_MODE?.trim();
      const mode =
        envMode && mod.DEV_MODES?.includes?.(envMode) ? envMode : undefined;
      let contextMax;
      const ctxIdx = process.argv.indexOf("--context-max");
      if (ctxIdx >= 0 && process.argv[ctxIdx + 1]) {
        const parsed = Number.parseInt(process.argv[ctxIdx + 1], 10);
        if (!Number.isNaN(parsed) && parsed > 0) contextMax = parsed;
      }
      const bootOpts = {};
      if (mode) bootOpts.mode = mode;
      if (contextMax) bootOpts.contextMax = contextMax;
      const adapter = await mod.createNextAgent(
        cwd,
        Object.keys(bootOpts).length > 0 ? bootOpts : undefined,
      );

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

function useJackalBoot() {
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

function useJackalUI() {
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

function useJackalSession() {
  const actionsRef = useRef(null);
  useTick();
  if (!actionsRef.current && state.adapter) {
    const a = state.adapter;
    actionsRef.current = {
      send: (text) => a.actions.send(text),
      abort: () => a.actions.abort(),
      resolveDialog: (id, value) => a.actions.resolveDialog(id, value),
      setModel: (provider, modelId) => a.actions.setModel(provider, modelId),
      clearSession: async () => {
        await a.actions.clearSession();
        state.screenEpoch += 1;
        emit();
        await forceInkRedraw();
      },
      compactSession: (opts) => a.actions.compactSession(opts),
      listSessions: (all) => a.actions.listSessions(all),
      resumeSession: (target) => a.actions.resumeSession(target),
      renameSession: (name) => a.actions.renameSession(name),
      exportSessionMarkdown: () => a.actions.exportSessionMarkdown(),
      getContextUsage: () => a.actions.getContextUsage(),
      getUsageLine: () => {
        const u = a.actions.getContextUsage();
        return `Context: ${u.used.toLocaleString()} / ${u.max.toLocaleString()} tokens (${u.percent}%)`;
      },
      setContextMax: (n) => a.actions.setContextMax(n),
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
      setMode: (mode) => a.actions.setMode(mode),
      cycleMode: () => a.actions.cycleMode(),
      approveTool: () => a.actions.approveTool(),
      rejectTool: () => a.actions.rejectTool(),
      runTool: (name, params) => a.actions.runTool(name, params ?? {}),
      runFixFlow: (max) => a.actions.runFixFlow(max ?? 3),
      runJacCheck: (files) => a.actions.runJacCheck(files),
      runJacDoctor: () => a.actions.runJacDoctor(),
      runJacFormat: (files) => a.actions.runJacFormat(files),
      runJacTest: (files) => a.actions.runJacTest(files),
      runOsp: (prompt) => a.actions.runOsp(prompt),
      runConvertPython: (path) => a.actions.runConvertPython(path),
      runIdiomReview: (paths) => a.actions.runIdiomReview(paths ?? []),
      runExplain: (mode, args) => a.actions.runExplain(mode, args),
      runInit: (opts) => a.actions.runInit(opts),
      runDiagramToModel: (source, content) => a.actions.runDiagramToModel(source, content ?? ""),
      exportSessionToFile: (path) => a.actions.exportSessionToFile(path),
      pickResumeSession: () => a.actions.pickResumeSession(),
      loadProjectFiles: () => listProjectFiles(process.env.JACKAL_AGENT_CWD || process.cwd()),
      enterExplorer: async () => {
        explorerState.loading = true;
        explorerState.error = null;
        explorerState.active = true;
        explorerState.selected = new Set();
        explorerState.index = 0;
        explorerState.filter = "";
        explorerState.tokenHint = "";
        emit();
        try {
          const cwd = process.env.JACKAL_AGENT_CWD || process.cwd();
          explorerState.files = await listProjectFiles(cwd);
          explorerState.loading = false;
        } catch (err) {
          explorerState.loading = false;
          explorerState.error = err?.message || String(err);
        }
        emit();
      },
      exitExplorer: () => {
        explorerState.active = false;
        explorerState.files = [];
        explorerState.selected = new Set();
        explorerState.filter = "";
        explorerState.tokenHint = "";
        explorerState.error = null;
        emit();
      },
      explorerMove: (delta) => {
        const list = filteredExplorerFiles();
        if (list.length === 0) return;
        explorerState.index = (explorerState.index + delta + list.length) % list.length;
        emit();
      },
      explorerToggle: () => {
        const list = filteredExplorerFiles();
        const file = list[explorerState.index];
        if (!file) return;
        if (explorerState.selected.has(file)) {
          explorerState.selected.delete(file);
        } else {
          explorerState.selected.add(file);
        }
        void refreshExplorerTokenHint();
      },
      explorerSetFilter: (text) => {
        explorerState.filter = text;
        explorerState.index = 0;
        emit();
      },
      explorerConfirm: () => {
        const mentions = [...explorerState.selected].map((f) => `@${f}`).join(" ");
        explorerState.active = false;
        emit();
        return mentions;
      },
      getExplorerState: () => ({
        active: explorerState.active,
        files: filteredExplorerFiles(),
        index: explorerState.index,
        selected: [...explorerState.selected],
        filter: explorerState.filter,
        tokenHint: explorerState.tokenHint,
        loading: explorerState.loading,
        error: explorerState.error,
      }),
      checkpointCreate: (name) => a.actions.checkpointCreate(name),
      checkpointList: () => a.actions.checkpointList(),
      checkpointLoad: (name, opts) => a.actions.checkpointLoad(name, opts),
      checkpointDelete: (name) => a.actions.checkpointDelete(name),
      tasksList: () => a.actions.tasksList(),
      tasksAdd: (title) => a.actions.tasksAdd(title),
      tasksRemove: (index) => a.actions.tasksRemove(index),
      tasksClear: () => a.actions.tasksClear(),
      getCustomCommandSlashNames: () => a.actions.getCustomCommandSlashNames(),
      showAgents: () => a.actions.showAgents(),
      showCommands: () => a.actions.showCommands(),
      showCheckpoints: () => a.actions.showCheckpoints(),
      showTasks: () => a.actions.showTasks(),
      showSessions: () => a.actions.showSessions(),
      showJacDoctor: () => a.actions.showJacDoctor(),
    };
  }
  return actionsRef.current;
}

function useExplorerState() {
  useTick();
  return {
    active: explorerState.active,
    files: filteredExplorerFiles(),
    index: explorerState.index,
    selected: [...explorerState.selected],
    filter: explorerState.filter,
    tokenHint: explorerState.tokenHint,
    loading: explorerState.loading,
    error: explorerState.error,
  };
}

function useScreenEpoch() {
  useTick();
  return state.screenEpoch;
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
        const customCommands = a.actions.getCustomCommandSlashNames?.() ?? [];
        const ctx = {
          authStepKind: step.kind,
          providers,
          models,
          authOptions,
          filePaths,
          customCommands,
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
  useJackalBoot,
  useJackalSession,
  useAgentState,
  useAgentStream,
  useMessages,
  useToolTimeline,
  useAuthFlow,
  useJackalUI,
  useCompletions,
  useExplorerState,
  useScreenEpoch,
};
