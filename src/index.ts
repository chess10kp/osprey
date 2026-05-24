export { AgentStore } from "./core/store.js";
export type { AgentSnapshot, AgentPhase, ToolExecution, TranscriptEntry, ToolTranscriptEntry } from "./core/store.js";
export { bridgeEvents } from "./core/bridge.js";
export { runNextAgentSmoke, createNextAgent, runJacCheck, runJacDoctor, runJacFormat, runJacTest, runJacRun } from "./core/adapter.js";
export type { NextAgentResult, CreateNextAgentOptions, JacDiagnostic, JacDoctorReport, CheckpointMetadata, CheckpointListItem, LoadCheckpointOptions, Task } from "./core/adapter.js";
export {
  createCheckpoint,
  deleteCheckpoint,
  listCheckpoints,
  loadCheckpoint,
  restoreCheckpointFiles,
  getModifiedFiles,
  formatCheckpointList,
  formatCheckpointOverlayRow,
  formatRelativeTime,
  validateCheckpointName,
  checkpointsDir,
} from "./workflow/checkpoints.js";
export {
  formatTaskOverlayRow,
  formatTasksOverlayHeader,
  taskStatusIcon,
} from "./ui/overlay-rows.js";
export type { CheckpointData } from "./workflow/checkpoints.js";
export {
  loadTasks,
  saveTasks,
  clearTasks,
  addTask,
  removeTaskByIndex,
  removeTaskById,
  updateTasks,
  formatTasksList,
  formatTaskLine,
  taskCounts,
  tasksPath,
  generateTaskId,
} from "./workflow/tasks.js";
export type { TaskStatus, TaskUpdate } from "./workflow/tasks.js";
export {
  listSessions,
  loadSessionById,
  resolveSessionTarget,
  getLastSession,
} from "./session/session-index.js";
export type { SessionIndexEntry, SessionRecord } from "./session/session-index.js";
export {
  computeContextUsage,
  estimateMessagesTokens,
  formatUsageLine,
  getContextMax,
} from "./workflow/context-usage.js";
export type { ContextUsage } from "./workflow/context-usage.js";
export { JackalUIContext } from "./core/ui-context.js";
export type { DialogRequest, Notification, JackalUIState } from "./core/ui-context.js";
export { AuthFlowStore } from "./auth/auth-flow.js";
export type { AuthFlowStep, ProviderEntry, ModelEntry, SelectOption, PromiseResolvers, AuthFlowState } from "./auth/auth-flow.js";
export { AuthActions } from "./auth/auth-actions.js";
export { getSuggestions } from "./ui/completions.js";
export type { CompletionContext, Suggestion } from "./ui/completions.js";
export type { DevMode } from "./agent/dev-mode.js";
export {
  DEV_MODES,
  PLAN_MODE_TOOLS,
  cycleMode,
  parseModeFlag,
  isDestructiveBash,
  shouldAutoApprove,
  isToolAllowedInPlanMode,
  resolveBootMode,
} from "./agent/dev-mode.js";
export type { PendingApproval } from "./agent/tool-approval.js";
export { ToolApprovalQueue } from "./agent/tool-approval.js";
export type { PendingSubagentApproval } from "./agent/subagent-approval.js";
export { SubagentApprovalQueue } from "./agent/subagent-approval.js";
export {
  SessionPermissions,
  loadAlwaysAllowTools,
  needsToolApproval,
  isAlwaysAllowedTool,
} from "./agent/session-permissions.js";
export { resolveDefaultMode } from "./config/project-config.js";
export { runCli, parseRunArgs, resolveRunMode, printRunUsage } from "./cli/run.js";
export type { RunCliOptions, RunCliResult } from "./cli/run.js";

// Auto-compact
export {
  shouldAutoCompact,
  buildMechanicalSummary,
  buildLlmSummaryPrompt,
  resolveAutoCompactConfig,
} from "./session/auto-compact.js";
export type {
  AutoCompactConfig,
  AutoCompactResult,
  CompactStrategy,
} from "./session/auto-compact.js";
export { summarizeForCompaction, wrapCompactionSummary } from "./session/llm-compact.js";

// Session retention
export { pruneSessions } from "./session/session-index.js";

// Skill index
export {
  buildSkillIndex,
  formatSkillCatalog,
  searchSkills,
  loadSkillBody,
  appendSkillCatalogToPrompt,
} from "./project/skill-index.js";
export type { SkillEntry } from "./project/skill-index.js";

// Project init
export {
  analyzeProject,
  generateAgentsMd,
  runProjectInit,
} from "./project/project-init.js";
export type { ProjectInfo, ProjectType } from "./project/project-init.js";

// Jac explain workflows
export {
  buildExplainPrompt,
  runExplain,
  runInit as runJacInit,
  runDiagramToModel,
  type ExplainMode,
} from "./jac/jac-workflows.js";

export {
  listProjectFiles,
  estimateTokensFromChars,
  formatTokenEstimate,
  estimateSelectionChars,
} from "./project/file-explorer.js";

// Mermaid ASCII renderer
export {
  renderMermaidAscii,
  detectDiagramType,
  parseFlowchart,
  renderFlowchartAscii,
} from "./render/mermaid-render.js";
export type { MermaidDiagram, MermaidDiagramType, MermaidNode, MermaidEdge } from "./render/mermaid-render.js";

// LSP tools
export {
  getFileDiagnostics,
  getMultiFileDiagnostics,
  getHoverInfo,
  findDefinitions,
  findReferences,
  formatLspDiagnostics,
  formatHoverInfo,
  formatLocations,
} from "./jac/lsp-tools.js";
export type { LspDiagnostic, LspHoverInfo, LspLocation } from "./jac/lsp-tools.js";

import { pathToFileURL } from "node:url";
import { runNextAgentSmoke } from "./core/adapter.js";
import { parseRunArgs, printRunUsage, runCli } from "./cli/run.js";

// Non-TTY headless: exit on SIGINT. Interactive TUI (facade) and `jackal run`
// in a terminal install their own handlers — do not register here when imported.
const __isMainModule =
  typeof process.argv[1] === "string" &&
  import.meta.url === pathToFileURL(process.argv[1]).href;

if (__isMainModule && !process.stdout.isTTY) {
  process.on("SIGINT", () => process.exit(130));
}

async function runSmokeCli(): Promise<number> {
  const cwd = process.env.JACKAL_AGENT_CWD || process.cwd();
  const result = await runNextAgentSmoke(cwd);

  if (result.ok) {
    console.log(
      `jackal smoke ok (snapshots=${result.snapshotCount}, dialogs=${result.dialogCount}, events=${result.eventTypes.length})`,
    );
    return 0;
  }

  console.error(`jackal smoke failed: ${result.error ?? "unknown error"}`);
  if (result.eventTypes.length > 0) {
    console.error(`events seen: ${result.eventTypes.join(", ")}`);
  }
  return 1;
}

const isMain = __isMainModule;

const wantsSmoke =
  process.argv.includes("--check") || process.env.JACKAL_SMOKE === "1";

const runArgv = process.argv.slice(2);
const wantsRun = runArgv[0] === "run" && runArgv[1] !== "--check";

async function runHeadlessCli(): Promise<number> {
  const parsed = parseRunArgs(runArgv);
  if (!parsed.ok) {
    console.error(`jackal run: ${parsed.error}`);
    printRunUsage();
    return 1;
  }

  const result = await runCli(parsed.options);
  if (result.error) {
    console.error(result.error);
  }
  return result.exitCode;
}

if (isMain && wantsRun) {
  runHeadlessCli()
    .then((code) => process.exit(code))
    .catch((err: unknown) => {
      const message = err instanceof Error ? err.message : String(err);
      console.error(`jackal run crashed: ${message}`);
      process.exit(1);
    });
} else if (isMain && wantsSmoke) {
  runSmokeCli()
    .then((code) => process.exit(code))
    .catch((err: unknown) => {
      const message = err instanceof Error ? err.message : String(err);
      console.error(`jackal smoke crashed: ${message}`);
      process.exit(1);
    });
}
