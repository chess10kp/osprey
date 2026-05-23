export { AgentStore } from "./store.js";
export type { AgentSnapshot, AgentPhase, ToolExecution } from "./store.js";
export { bridgeEvents } from "./bridge.js";
export { runNextAgentSmoke, createNextAgent, runJacCheck, runJacDoctor, runJacFormat, runJacTest, runJacRun } from "./adapter.js";
export type { NextAgentResult, CreateNextAgentOptions, JacDiagnostic, JacDoctorReport, CheckpointMetadata, CheckpointListItem, LoadCheckpointOptions, Task } from "./adapter.js";
export {
  createCheckpoint,
  deleteCheckpoint,
  listCheckpoints,
  loadCheckpoint,
  restoreCheckpointFiles,
  getModifiedFiles,
  formatCheckpointList,
  validateCheckpointName,
  checkpointsDir,
} from "./runtime/checkpoints.js";
export type { CheckpointData } from "./runtime/checkpoints.js";
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
} from "./runtime/tasks.js";
export type { TaskStatus, TaskUpdate } from "./runtime/tasks.js";
export {
  listSessions,
  loadSessionById,
  resolveSessionTarget,
  getLastSession,
} from "./runtime/session-index.js";
export type { SessionIndexEntry, SessionRecord } from "./runtime/session-index.js";
export {
  computeContextUsage,
  estimateMessagesTokens,
  formatUsageLine,
  getContextMax,
} from "./runtime/context-usage.js";
export type { ContextUsage } from "./runtime/context-usage.js";
export { JackalUIContext } from "./ui-context.js";
export type { DialogRequest, Notification, JackalUIState } from "./ui-context.js";
export { AuthFlowStore } from "./auth-flow.js";
export type { AuthFlowStep, ProviderEntry, ModelEntry, SelectOption, PromiseResolvers, AuthFlowState } from "./auth-flow.js";
export { AuthActions } from "./auth-actions.js";
export { getSuggestions } from "./completions.js";
export type { CompletionContext, Suggestion } from "./completions.js";
export type { DevMode } from "./runtime/dev-mode.js";
export {
  DEV_MODES,
  PLAN_MODE_TOOLS,
  cycleMode,
  parseModeFlag,
  isDestructiveBash,
  shouldAutoApprove,
  isToolAllowedInPlanMode,
  resolveBootMode,
} from "./runtime/dev-mode.js";
export type { PendingApproval } from "./runtime/tool-approval.js";
export { ToolApprovalQueue } from "./runtime/tool-approval.js";
export { resolveDefaultMode } from "./runtime/project-config.js";
export { runCli, parseRunArgs, resolveRunMode, printRunUsage } from "./cli-run.js";
export type { RunCliOptions, RunCliResult } from "./cli-run.js";

// Auto-compact
export {
  shouldAutoCompact,
  buildMechanicalSummary,
  buildLlmSummaryPrompt,
  resolveAutoCompactConfig,
} from "./runtime/auto-compact.js";
export type { AutoCompactConfig, AutoCompactResult } from "./runtime/auto-compact.js";

// Session retention
export { pruneSessions } from "./runtime/session-index.js";

// Skill index
export {
  buildSkillIndex,
  formatSkillCatalog,
  searchSkills,
  loadSkillBody,
  appendSkillCatalogToPrompt,
} from "./runtime/skill-index.js";
export type { SkillEntry } from "./runtime/skill-index.js";

// Project init
export {
  analyzeProject,
  generateAgentsMd,
  runProjectInit,
} from "./runtime/project-init.js";
export type { ProjectInfo, ProjectType } from "./runtime/project-init.js";

// Jac explain workflows
export {
  buildExplainPrompt,
  runExplain,
  runInit as runJacInit,
  type ExplainMode,
} from "./runtime/jac-workflows.js";

// Mermaid ASCII renderer
export {
  renderMermaidAscii,
  detectDiagramType,
  parseFlowchart,
  renderFlowchartAscii,
} from "./runtime/mermaid-render.js";
export type { MermaidDiagram, MermaidDiagramType, MermaidNode, MermaidEdge } from "./runtime/mermaid-render.js";

import { pathToFileURL } from "node:url";
import { runNextAgentSmoke } from "./adapter.js";
import { parseRunArgs, printRunUsage, runCli } from "./cli-run.js";

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

const isMain =
  typeof process.argv[1] === "string" &&
  import.meta.url === pathToFileURL(process.argv[1]).href;

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
