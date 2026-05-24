// Adapter — Jackal agent runtime wired into the AgentStore.

import { AgentStore } from "./store.js";
import { bridgeEvents, seedStoreFromSession } from "./bridge.js";
import { JackalUIContext } from "./ui-context.js";
import { AuthFlowStore } from "../auth/auth-flow.js";
import { AuthActions } from "../auth/auth-actions.js";
import { JackalAuth, JackalModels } from "../auth/auth.js";
import { JackalSessionManager } from "../session/session.js";
import { JackalAgentSession, type CompactContextOptions, type CompactContextResult } from "../session/agent-session.js";
import type { DevMode } from "../agent/dev-mode.js";
import { resolveBootMode } from "../agent/dev-mode.js";
import { loadProjectConfig } from "../config/project-config.js";
import {
  listSessions as listSessionIndex,
  resolveSessionTarget,
  type SessionIndexEntry,
} from "../session/session-index.js";
import { join } from "node:path";
import { mkdir, writeFile } from "node:fs/promises";
import {
  runJacCheck as runJacCheckCli,
  runJacFormat as runJacFormatCli,
  runJacTest as runJacTestCli,
  runJacRun as runJacRunCli,
} from "../jac/jac-cli.js";
import { runJacDoctor as runJacDoctorCli } from "../jac/jac-doctor.js";
import {
  runOspWorkflow,
  runConvertPython,
  runIdiomReview,
  runExplain,
  runInit,
  runDiagramToModel,
  type ExplainMode,
} from "../jac/jac-workflows.js";
import { listProjectFiles, estimateSelectionChars } from "../project/file-explorer.js";
import { formatSubagentCatalog } from "../orchestration/subagents.js";
import { formatChainCatalog } from "../orchestration/chains.js";
import { formatCustomCommandCatalog } from "../workflow/custom-commands.js";
import type { JacDiagnostic } from "../jac/jac-types.js";
import type { JacDoctorReport } from "../jac/jac-doctor.js";
import {
  createCheckpoint,
  deleteCheckpoint,
  getModifiedFiles,
  listCheckpoints,
  loadCheckpoint,
  restoreCheckpointFiles,
  type CheckpointListItem,
  type CheckpointMetadata,
  type LoadCheckpointOptions,
} from "../workflow/checkpoints.js";
import {
  addTask,
  clearTasks,
  loadTasks,
  removeTaskByIndex,
  type Task,
} from "../workflow/tasks.js";
import { expandContextInput } from "../workflow/context-input.js";
import { formatCheckpointList } from "../workflow/checkpoints.js";
import { formatTasksList } from "../workflow/tasks.js";

export interface CreateNextAgentOptions {
  authPath?: string;
  sessionDir?: string;
  mode?: DevMode;
  /** Override model context window (tokens). Also read from `JACKAL_CONTEXT_MAX`. */
  contextMax?: number;
  /** Start with a specific session ID instead of resuming the latest. */
  sessionId?: string;
}

function resolveContextMax(cwd: string, options?: CreateNextAgentOptions): number | null {
  if (typeof options?.contextMax === "number" && options.contextMax > 0) {
    return options.contextMax;
  }
  const env = process.env.JACKAL_CONTEXT_MAX;
  if (env) {
    const parsed = Number.parseInt(env, 10);
    if (!Number.isNaN(parsed) && parsed > 0) return parsed;
  }
  const cfg = loadProjectConfig(cwd) as { contextMax?: number };
  if (typeof cfg.contextMax === "number" && cfg.contextMax > 0) {
    return cfg.contextMax;
  }
  return null;
}

function sessionStorageDir(cwd: string, override?: string): string {
  return override ?? join(cwd, ".jackal", "sessions");
}

export interface NextAgentResult {
  ok: boolean;
  eventTypes: string[];
  snapshotCount: number;
  dialogCount: number;
  error?: string;
}

export type { JacDiagnostic, JacDoctorReport };
export type { CheckpointMetadata, CheckpointListItem, LoadCheckpointOptions };
export type { Task };

/** Run `jac check` with structured diagnostics (headless, no session required). */
export async function runJacCheck(
  cwd: string,
  files?: string[],
): Promise<{
  diagnostics: JacDiagnostic[];
  rawOutput: string;
  exitCode: number;
  exitError?: string;
}> {
  return runJacCheckCli(cwd, files);
}

/** Run Jac environment detection report. */
export async function runJacDoctor(cwd: string): Promise<JacDoctorReport> {
  return runJacDoctorCli(cwd);
}

/** Run `jac format` on files. */
export async function runJacFormat(
  cwd: string,
  files: string[],
): Promise<{ changed: boolean; rawOutput: string; exitCode: number }> {
  return runJacFormatCli(cwd, files);
}

/** Run `jac test` with best-effort diagnostic parsing. */
export async function runJacTest(
  cwd: string,
  files?: string[],
): Promise<{
  passed: boolean;
  rawOutput: string;
  exitCode: number;
  diagnostics: JacDiagnostic[];
}> {
  return runJacTestCli(cwd, files);
}

/** Run `jac run <file>` and capture runtime output. */
export async function runJacRun(
  cwd: string,
  file: string,
  options?: { args?: string[]; timeoutMs?: number },
): Promise<{
  stdout: string;
  stderr: string;
  exitCode: number;
  error?: string;
}> {
  return runJacRunCli(cwd, file, options);
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
    const bootModel = session.currentModel;
    seedStoreFromSession(store, {
      mode: session.mode,
      provider: bootModel.provider,
      model: bootModel.id,
      sessionId: sessionManager.sessionId,
      sessionName: sessionManager.sessionName,
      messages: session.messages,
    });
    await session.initialize();
    session.scheduleMcpConnect();
    session.scheduleLspConnect();

    try {
      await session.sendUserMessage("Respond with exactly: headless-ok");
      await new Promise((r) => setTimeout(r, 1500));
    } finally {
      unsubEvents();
      unsubBridge();
      await session.shutdownBackground();
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
    compactSession: (options?: CompactContextOptions) => Promise<CompactContextResult>;
    listSessions: (all?: boolean) => SessionIndexEntry[];
    resumeSession: (target: string) => Promise<void>;
    renameSession: (name: string) => void;
    exportSessionMarkdown: () => string;
    exportSessionToFile: (path?: string) => Promise<string>;
    pickResumeSession: () => Promise<void>;
    listProjectFiles: () => Promise<string[]>;
    estimateFileSelection: (paths: string[]) => Promise<{ chars: number; tokens: number; warn: boolean }>;
    getContextUsage: () => ReturnType<JackalAgentSession["getContextUsage"]>;
    setContextMax: (n: number | null) => void;
    getCustomCommandSlashNames: () => string[];
    showAgents: () => Promise<void>;
    showCommands: () => Promise<void>;
    showCheckpoints: () => Promise<void>;
    showTasks: () => Promise<void>;
    showSessions: () => Promise<void>;
    showJacDoctor: () => Promise<void>;
    runTool: (name: string, params?: Record<string, unknown>) => Promise<string>;
    runFixFlow: (maxAttempts?: number) => Promise<string>;
    runJacCheck: (files?: string[]) => Promise<Awaited<ReturnType<typeof runJacCheck>>>;
    runJacDoctor: () => Promise<JacDoctorReport>;
    runJacFormat: (files: string[]) => Promise<Awaited<ReturnType<typeof runJacFormat>>>;
    runJacTest: (files?: string[]) => Promise<Awaited<ReturnType<typeof runJacTest>>>;
    runJacRun: (file: string, args?: string[]) => Promise<Awaited<ReturnType<typeof runJacRun>>>;
    runOsp: (prompt: string) => Promise<void>;
    runConvertPython: (path: string) => Promise<void>;
    runIdiomReview: (paths?: string[]) => Promise<void>;
    runExplain: (mode: ExplainMode, args: string) => Promise<void>;
    runInit: (options?: { force?: boolean; lean?: boolean }) => Promise<void>;
    runDiagramToModel: (source: string, content?: string) => Promise<void>;
    checkpointCreate: (name?: string) => Promise<CheckpointMetadata>;
    checkpointList: () => Promise<CheckpointListItem[]>;
    checkpointLoad: (
      name: string,
      options?: LoadCheckpointOptions,
    ) => Promise<{ metadata: CheckpointMetadata; filesRestored: number; conversationRestored: boolean }>;
    checkpointDelete: (name: string) => Promise<void>;
    tasksList: () => Promise<Task[]>;
    tasksAdd: (title: string) => Promise<Task>;
    tasksRemove: (index: number) => Promise<Task | null>;
    tasksClear: () => Promise<void>;
    setMode: (mode: DevMode) => void;
    cycleMode: () => DevMode;
    approveTool: () => boolean;
    rejectTool: () => boolean;
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
  const initialMode = resolveBootMode(cwd, options?.mode);
  const contextMaxOverride = resolveContextMax(cwd, options);
  store.setMode(initialMode);

  const session = new JackalAgentSession({
    cwd,
    auth,
    models,
    sessionManager,
    initialMode,
    contextMaxOverride,
    onPendingApprovalChange: (pending) => {
      store.setPendingApproval(pending);
    },
    onPendingSubagentApprovalChange: (pending) => {
      store.setPendingSubagentApproval(pending);
    },
  });

  const storageDir = sessionStorageDir(cwd, options?.sessionDir);

  const unsubBridge = bridgeEvents(session, store);
  const bootModel = session.currentModel;
  seedStoreFromSession(store, {
    mode: session.mode,
    provider: bootModel.provider,
    model: bootModel.id,
    sessionId: sessionManager.sessionId,
    sessionName: sessionManager.sessionName,
    messages: session.messages,
  });
  await session.initialize();
  store.markReady();
  session.scheduleMcpConnect();
  session.scheduleLspConnect();
  await clearTasks(cwd);

  return {
    store,
    uiContext,
    authFlow,
    authActions,
    actions: {
      send: async (text: string) => {
        const slashExpanded = session.resolveSlashCommand(text);
        let outgoing = slashExpanded ?? text;
        if (!slashExpanded && (outgoing.includes("@") || outgoing.trimStart().startsWith("!"))) {
          try {
            outgoing = await expandContextInput(cwd, outgoing);
          } catch (err) {
            uiContext.notify(`Context expand failed: ${String(err)}`, "error");
          }
        }
        store.pushUserMessage(text);
        try {
          const result = await session.sendUserMessage(outgoing);
          if (result === "queued") {
            uiContext.notify("Message queued — will run after the current turn finishes.", "info");
          }
        } catch (err) {
          uiContext.notify(String(err instanceof Error ? err.message : err), "error");
        }
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
        try {
          await session.abort();
        } catch {
          /* ignore */
        }
        store.clearTranscript();
        uiContext.reset();
        session.resetForNewSession();
        await clearTasks(cwd);
        uiContext.notify("Chat cleared.", "success");
      },
      compactSession: async (compactOptions?: CompactContextOptions) => {
        const result = session.compactContext(compactOptions ?? {});
        if (result.preview && result.summaryPreview) {
          uiContext.notify(
            `Preview: ${result.dropped} message(s) would drop (${result.messageCountBefore} → ${result.messageCountAfter}).`,
            "info",
          );
        } else if (result.restored) {
          uiContext.notify("Restored pre-compaction backup.", "success");
        } else if (result.compacted) {
          uiContext.notify(`Compacted ${result.dropped} older message(s).`, "success");
        }
        return result;
      },
      listSessions: (all = false) => {
        return listSessionIndex(storageDir, all ? undefined : { cwd });
      },
      resumeSession: async (target: string) => {
        const record = resolveSessionTarget(storageDir, target, { cwd });
        if (!record) {
          throw new Error(`Session not found: ${target}`);
        }
        try {
          await session.abort();
        } catch {
          /* ignore */
        }
        session.resumeFromRecord(record);
        uiContext.notify(`Resumed "${record.sessionName}" (${record.messages.length} messages).`, "success");
      },
      renameSession: (name: string) => {
        session.renameSession(name);
        uiContext.notify(`Session renamed to "${name.trim()}".`, "success");
      },
      exportSessionMarkdown: () => session.exportSessionMarkdown(),
      exportSessionToFile: async (outPath?: string) => {
        const md = session.exportSessionMarkdown();
        const exportDir = join(cwd, ".jackal", "exports");
        await mkdir(exportDir, { recursive: true });
        const file =
          outPath?.trim() ||
          join(exportDir, `session-${sessionManager.sessionId}-${Date.now()}.md`);
        await writeFile(file, md, "utf-8");
        uiContext.notify(`Exported session to ${file}`, "success");
        return file;
      },
      pickResumeSession: async () => {
        const items = listSessionIndex(storageDir, { cwd });
        if (items.length === 0) {
          uiContext.notify("No prior sessions for this project.", "info");
          return;
        }
        const labels = items.map(
          (s, i) => `${i + 1}. ${s.name} (${s.messageCount} msgs, ${s.updatedAt.slice(0, 10)})`,
        );
        const choice = await uiContext.select("Resume session", labels);
        if (!choice) return;
        const numMatch = choice.match(/^(\d+)\./);
        const target = numMatch ? String(numMatch[1]) : choice;
        await session.abort().catch(() => undefined);
        const record = resolveSessionTarget(storageDir, target, { cwd });
        if (!record) {
          uiContext.notify(`Session not found: ${target}`, "error");
          return;
        }
        session.resumeFromRecord(record);
        uiContext.notify(
          `Resumed "${record.sessionName}" (${record.messages.length} messages).`,
          "success",
        );
      },
      listProjectFiles: () => listProjectFiles(cwd),
      estimateFileSelection: (paths: string[]) => estimateSelectionChars(cwd, paths),
      getContextUsage: () => session.getContextUsage(),
      setContextMax: (n: number | null) => {
        session.setContextMax(n);
        uiContext.notify(
          n ? `Context max set to ${n.toLocaleString()} tokens.` : "Context max reset to model default.",
          "info",
        );
      },
      getCustomCommandSlashNames: () => session.getCustomCommandSlashNames(),
      showAgents: async () => {
        const text = [formatSubagentCatalog(cwd), "", formatChainCatalog(cwd)].join("\n");
        store.pushUserMessage("/agents");
        session.appendAssistantNotice(text);
      },
      showCommands: async () => {
        const text = formatCustomCommandCatalog(cwd);
        store.pushUserMessage("/commands");
        session.appendAssistantNotice(text);
      },
      showCheckpoints: async () => {
        const items = await listCheckpoints(cwd);
        const text = formatCheckpointList(items);
        store.pushUserMessage("/checkpoint list");
        session.appendAssistantNotice(text || "(no checkpoints)");
      },
      showTasks: async () => {
        const tasks = await loadTasks(cwd);
        const text = formatTasksList(tasks);
        store.pushUserMessage("/tasks");
        session.appendAssistantNotice(text || "(no tasks)");
      },
      showSessions: async () => {
        const items = listSessionIndex(storageDir, { cwd });
        const lines = items.map(
          (s, i) =>
            `${i + 1}. ${s.name} (${s.id.slice(0, 8)}…) — ${s.messageCount} msgs — ${s.updatedAt}`,
        );
        store.pushUserMessage("/resume");
        session.appendAssistantNotice(lines.join("\n") || "(no prior sessions)");
      },
      showJacDoctor: async () => {
        store.pushUserMessage("/jac-doctor");
        const report = await runJacDoctor(cwd);
        session.appendAssistantNotice(report.summary);
      },
      runTool: async (name: string, params?: Record<string, unknown>) => {
        return session.runTool(name, params ?? {});
      },
      runFixFlow: async (maxAttempts?: number) => {
        return session.runFixFlow(maxAttempts ?? 3);
      },
      runJacCheck: async (files?: string[]) => runJacCheck(cwd, files),
      runJacDoctor: async () => runJacDoctor(cwd),
      runJacFormat: async (files: string[]) => runJacFormat(cwd, files),
      runJacTest: async (files?: string[]) => runJacTest(cwd, files),
      runJacRun: async (file: string, args?: string[]) => runJacRun(cwd, file, { args }),
      runOsp: async (prompt: string) => {
        const desc = prompt.trim();
        if (!desc) {
          throw new Error("Usage: /osp <description>");
        }
        store.pushUserMessage(`/osp ${desc}`);
        await runOspWorkflow(session, desc);
      },
      runConvertPython: async (path: string) => {
        const target = path.trim();
        if (!target) {
          throw new Error("Usage: /jac convert-python <path.py>");
        }
        store.pushUserMessage(`/jac convert-python ${target}`);
        await runConvertPython(session, target);
      },
      runIdiomReview: async (paths: string[] = []) => {
        const label =
          paths.length > 0
            ? `/jac review-idioms ${paths.join(" ")}`
            : "/jac review-idioms";
        store.pushUserMessage(label);
        await runIdiomReview(session, paths);
      },
      runExplain: async (mode: ExplainMode, args: string) => {
        const label = `/jac explain ${mode} ${args}`.trim();
        store.pushUserMessage(label);
        await runExplain(session, mode, args);
      },
      runInit: async (options?: { force?: boolean; lean?: boolean }) => {
        store.pushUserMessage("/init");
        const result = await runInit(session, cwd, options);
        session.appendAssistantNotice(result);
      },
      runDiagramToModel: async (source: string, content = "") => {
        const label = `/jac diagram-to-model ${source}`.trim();
        store.pushUserMessage(label);
        await runDiagramToModel(session, source, content);
      },
      checkpointCreate: async (name?: string) => {
        const model = session.currentModel;
        const metadata = await createCheckpoint(cwd, {
          name,
          messages: session.messages,
          provider: model.provider,
          model: model.id,
        });
        uiContext.notify(
          `Checkpoint "${metadata.name}" saved (${metadata.messageCount} msgs, ${metadata.filesChanged.length} files).`,
          "success",
        );
        return metadata;
      },
      checkpointList: async () => listCheckpoints(cwd),
      checkpointLoad: async (name, options = {}) => {
        const data = await loadCheckpoint(cwd, name);

        if (options.createBackup !== false && data.fileSnapshots.size > 0) {
          const dirty = getModifiedFiles(cwd);
          const wouldOverwrite = [...data.fileSnapshots.keys()].some((f) => dirty.includes(f));
          if (wouldOverwrite) {
            const model = session.currentModel;
            await createCheckpoint(cwd, {
              messages: session.messages,
              provider: model.provider,
              model: model.id,
              modifiedFiles: dirty,
            });
            uiContext.notify("Auto-backup checkpoint created before restore.", "info");
          }
        }

        await restoreCheckpointFiles(cwd, data.fileSnapshots);

        let conversationRestored = false;
        if (options.restoreConversation) {
          session.restoreCheckpointConversation(data.conversation.messages, {
            provider: data.metadata.provider.name,
            id: data.metadata.provider.model,
          });
          conversationRestored = true;
        }

        uiContext.notify(
          `Loaded checkpoint "${name}" (${data.fileSnapshots.size} files restored${conversationRestored ? ", conversation restored" : ""}).`,
          "success",
        );

        return {
          metadata: data.metadata,
          filesRestored: data.fileSnapshots.size,
          conversationRestored,
        };
      },
      checkpointDelete: async (name: string) => {
        await deleteCheckpoint(cwd, name);
        uiContext.notify(`Deleted checkpoint "${name}".`, "success");
      },
      tasksList: async () => loadTasks(cwd),
      tasksAdd: async (title: string) => {
        const task = await addTask(cwd, title);
        uiContext.notify(`Added task: ${task.title}`, "success");
        return task;
      },
      tasksRemove: async (index: number) => {
        const removed = await removeTaskByIndex(cwd, index - 1);
        if (!removed) {
          throw new Error(`Task ${index} not found`);
        }
        uiContext.notify(`Removed task: ${removed.title}`, "success");
        return removed;
      },
      tasksClear: async () => {
        await clearTasks(cwd);
        uiContext.notify("All tasks cleared.", "success");
      },
      setMode: (mode: DevMode) => {
        session.setMode(mode);
        store.setMode(mode);
        uiContext.notify(`Mode: ${mode}`, "info");
      },
      cycleMode: () => {
        const next = session.cycleMode();
        store.setMode(next);
        uiContext.notify(`Mode: ${next}`, "info");
        return next;
      },
      approveTool: () => session.approveTool(),
      rejectTool: () => session.rejectTool(),
      dispose: () => {
        unsubBridge();
        void session.shutdownBackground();
        session.dispose();
        store.reset();
        authFlow.reset();
      },
    },
  };
}
