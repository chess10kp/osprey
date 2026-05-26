// Bridge from TypeScript runtime to lib/jac/jac Python toolchain (cli + doctor).

import { spawn, spawnSync } from "node:child_process";
import { accessSync, constants, existsSync } from "node:fs";
import { delimiter, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { JacDiagnostic } from "./jac-types.js";

const BRIDGE_REL = "lib/jac/bridge/toolchain_stdio.py";

interface BridgeResponse<T = unknown> {
  ok: boolean;
  error?: string;
  trace?: string;
  result?: T;
  diagnostics?: JacDiagnostic[];
  fingerprint?: string;
  formatted?: string;
  binary?: string | null;
}

let cachedJackalRoot: string | null = null;

/** Resolve Jackal repo root (directory containing lib/jac/). */
export function resolveJackalRoot(): string {
  if (cachedJackalRoot) return cachedJackalRoot;

  if (process.env.JACKAL_ROOT && existsSync(join(process.env.JACKAL_ROOT, BRIDGE_REL))) {
    cachedJackalRoot = process.env.JACKAL_ROOT;
    return cachedJackalRoot;
  }

  if (process.env.JACKAL_AGENT_DIR) {
    const fromPi = join(process.env.JACKAL_AGENT_DIR, "..");
    if (existsSync(join(fromPi, BRIDGE_REL))) {
      cachedJackalRoot = fromPi;
      return cachedJackalRoot;
    }
  }

  const here = dirname(fileURLToPath(import.meta.url));
  for (const candidate of [join(here, "../.."), join(here, "../../..")]) {
    if (existsSync(join(candidate, BRIDGE_REL))) {
      cachedJackalRoot = candidate;
      return cachedJackalRoot;
    }
  }

  throw new Error(
    `Jackal toolchain bridge not found (${BRIDGE_REL}). Set JACKAL_ROOT to the repo root.`,
  );
}

function resolvePython(): string {
  return process.env.JACKAL_TOOLCHAIN_PYTHON || "python3";
}

function parseBridgeLine<T>(line: string, request: Record<string, unknown>): T {
  let parsed: BridgeResponse<T>;
  try {
    parsed = JSON.parse(line) as BridgeResponse<T>;
  } catch {
    throw new Error(`toolchain bridge invalid JSON: ${line.slice(0, 200)}`);
  }
  if (!parsed.ok) {
    const detail = parsed.trace ? `${parsed.error}\n${parsed.trace}` : parsed.error;
    throw new Error(detail || "toolchain bridge failed");
  }
  if ("result" in parsed && parsed.result !== undefined) {
    return parsed.result as T;
  }
  if ("diagnostics" in parsed) {
    return parsed.diagnostics as T;
  }
  if ("fingerprint" in parsed) {
    return parsed.fingerprint as T;
  }
  if ("formatted" in parsed) {
    return parsed.formatted as T;
  }
  if ("binary" in parsed) {
    return parsed.binary as T;
  }
  throw new Error(`toolchain bridge: unexpected response for op ${request.op}`);
}

function invokeBridgeSync<T>(request: Record<string, unknown>): T {
  const root = resolveJackalRoot();
  const script = join(root, BRIDGE_REL);
  const python = resolvePython();
  const child = spawnSync(python, [script], {
    cwd: root,
    input: JSON.stringify(request),
    encoding: "utf-8",
    env: { ...process.env, PYTHONUNBUFFERED: "1" },
  });
  const stdout = child.stdout?.trim() ?? "";
  const stderr = child.stderr?.trim() ?? "";
  if (child.error) throw child.error;
  const line = stdout.split("\n").pop() ?? "";
  if (!line) {
    throw new Error(
      stderr || `toolchain bridge exited ${child.status ?? "?"} with no output (python=${python})`,
    );
  }
  return parseBridgeLine<T>(line, request);
}

async function invokeBridge<T>(request: Record<string, unknown>): Promise<T> {
  const root = resolveJackalRoot();
  const script = join(root, BRIDGE_REL);
  const python = resolvePython();

  return new Promise((resolve, reject) => {
    const child = spawn(python, [script], {
      cwd: root,
      stdio: ["pipe", "pipe", "pipe"],
      env: { ...process.env, PYTHONUNBUFFERED: "1" },
    });

    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk: Buffer) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk: Buffer) => {
      stderr += chunk.toString();
    });

    child.on("error", (err) => reject(err));
    child.on("close", (code) => {
      const line = stdout.trim().split("\n").pop() ?? "";
      if (!line) {
        reject(
          new Error(
            stderr.trim() ||
              `toolchain bridge exited ${code ?? "?"} with no output (python=${python})`,
          ),
        );
        return;
      }
      try {
        resolve(parseBridgeLine<T>(line, request));
      } catch (err) {
        reject(err);
      }
    });

    child.stdin.write(JSON.stringify(request));
    child.stdin.end();
  });
}

/** Fast PATH probe for LSP boot (same candidates as lib/jac/jac/_cli_toolchain.py). */
export function findJacBinaryOnPath(): string | null {
  const candidates = ["jac", "jaclang"];
  const isWin = process.platform === "win32";
  const extensions = isWin ? ["", ".cmd", ".exe"] : [""];
  const pathDirs = (process.env.PATH || "").split(delimiter).filter(Boolean);
  for (const cmd of candidates) {
    for (const dir of pathDirs) {
      for (const ext of extensions) {
        try {
          accessSync(join(dir, `${cmd}${ext}`), constants.X_OK);
          return cmd;
        } catch {
          /* not found */
        }
      }
    }
  }
  return null;
}

export async function bridgeFindJacBinary(): Promise<string | null> {
  return invokeBridge<string | null>({ op: "find_binary" });
}

export async function bridgeParseJacCheckOutput(
  stdout: string,
  stderr: string,
): Promise<JacDiagnostic[]> {
  const diags = await invokeBridge<JacDiagnostic[]>({
    op: "parse_check",
    stdout,
    stderr,
  });
  return diags.map(normalizeDiagnostic);
}

export function bridgeFingerprintErrors(errors: JacDiagnostic[]): string {
  return invokeBridgeSync<string>({ op: "fingerprint", errors });
}

export function bridgeFormatDiagnostics(diagnostics: JacDiagnostic[]): string {
  return invokeBridgeSync<string>({ op: "format_diagnostics", diagnostics });
}

export interface JacCommandResult {
  stdout: string;
  stderr: string;
  rawOutput: string;
  exitCode: number;
  diagnostics: JacDiagnostic[];
}

export async function bridgeRunJacCommand(
  cmd: string[],
  cwd: string,
  options?: { timeoutMs?: number; parseDiagnostics?: boolean },
): Promise<JacCommandResult> {
  const result = await invokeBridge<{
    stdout: string;
    stderr: string;
    rawOutput: string;
    exitCode: number;
    diagnostics: JacDiagnostic[];
  }>({
    op: "run_command",
    cmd,
    cwd,
    timeoutMs: options?.timeoutMs ?? 120_000,
    parseDiagnostics: options?.parseDiagnostics ?? cmd[0] === "check",
  });
  return {
    ...result,
    diagnostics: result.diagnostics.map(normalizeDiagnostic),
  };
}

export async function bridgeRunJacCheck(
  cwd: string,
  files?: string[],
): Promise<{
  diagnostics: JacDiagnostic[];
  rawOutput: string;
  exitCode: number;
  exitError?: string;
}> {
  const result = await invokeBridge<{
    diagnostics: JacDiagnostic[];
    rawOutput: string;
    exitCode: number;
    exitError?: string;
  }>({ op: "run_check", cwd, files });
  return {
    ...result,
    diagnostics: result.diagnostics.map(normalizeDiagnostic),
  };
}

export async function bridgeRunJacFormat(
  cwd: string,
  files: string[],
): Promise<{ changed: boolean; rawOutput: string; exitCode: number }> {
  return invokeBridge({ op: "run_format", cwd, files });
}

export async function bridgeRunJacTest(
  cwd: string,
  files?: string[],
): Promise<{
  passed: boolean;
  rawOutput: string;
  exitCode: number;
  diagnostics: JacDiagnostic[];
}> {
  const result = await invokeBridge<{
    passed: boolean;
    rawOutput: string;
    exitCode: number;
    diagnostics: JacDiagnostic[];
  }>({ op: "run_test", cwd, files });
  return {
    ...result,
    diagnostics: result.diagnostics.map(normalizeDiagnostic),
  };
}

export async function bridgeRunJacRun(
  cwd: string,
  file: string,
  options?: { args?: string[]; timeoutMs?: number },
): Promise<{
  stdout: string;
  stderr: string;
  exitCode: number;
  error?: string;
}> {
  return invokeBridge({
    op: "run_run",
    cwd,
    file,
    args: options?.args,
    timeoutMs: options?.timeoutMs ?? 60_000,
  });
}

export interface JacDoctorReport {
  jacBinary: string | null;
  jacVersion: string | null;
  mcpAvailable: boolean;
  mcpDetail: string;
  jacTomlPath: string | null;
  jacTomlEntryPoint: string | null;
  jackalConfigPath: string | null;
  projectConfig: Record<string, unknown>;
  jacFiles: string[];
  summary: string;
}

export async function bridgeRunJacDoctor(cwd: string): Promise<JacDoctorReport> {
  return invokeBridge<JacDoctorReport>({ op: "doctor", cwd });
}

export interface ResolvedLspConfig {
  enabled: boolean;
  autoStart: string[];
  servers: Record<string, { command: string; args: string[]; env?: Record<string, string> }>;
}

export function bridgeResolveLspConfig(
  cwd: string,
  projectConfig: Record<string, unknown> = {},
): ResolvedLspConfig {
  return invokeBridgeSync<ResolvedLspConfig>({
    op: "resolve_lsp_config",
    cwd,
    projectConfig,
  });
}

export interface BridgeListProjectFilesOptions {
  maxDepth?: number;
  maxFiles?: number;
  respectGitignore?: boolean;
}

export interface BridgeSelectionEstimate {
  chars: number;
  tokens: number;
  warn: boolean;
}

export async function bridgeListProjectFiles(
  cwd: string,
  options?: BridgeListProjectFilesOptions,
): Promise<string[]> {
  return invokeBridge<string[]>({
    op: "project_list_files",
    cwd,
    maxDepth: options?.maxDepth,
    maxFiles: options?.maxFiles,
    respectGitignore: options?.respectGitignore,
  });
}

export async function bridgeEstimateSelectionChars(
  cwd: string,
  paths: string[],
): Promise<BridgeSelectionEstimate> {
  return invokeBridge<BridgeSelectionEstimate>({
    op: "project_estimate_selection",
    cwd,
    paths,
  });
}

export interface BridgeProjectConfig {
  [key: string]: unknown;
}

export async function bridgeLoadProjectConfig(
  cwd: string,
): Promise<BridgeProjectConfig> {
  return invokeBridge<BridgeProjectConfig>({
    op: "project_load_config",
    cwd,
  });
}

export async function bridgeFindConfigPath(
  cwd: string,
): Promise<string | null> {
  return invokeBridge<string | null>({
    op: "project_find_config_path",
    cwd,
  });
}

export async function bridgeResolveDefaultMode(
  config: BridgeProjectConfig,
): Promise<string> {
  return invokeBridge<string>({
    op: "project_resolve_default_mode",
    config,
  });
}

/** Sync variant — used by project-config.ts which must stay synchronous. */
export function bridgeLoadProjectConfigSync(
  cwd: string,
): BridgeProjectConfig {
  return invokeBridgeSync<BridgeProjectConfig>({
    op: "project_load_config",
    cwd,
  });
}

export function bridgeFindConfigPathSync(
  cwd: string,
): string | null {
  return invokeBridgeSync<string | null>({
    op: "project_find_config_path",
    cwd,
  });
}

export function bridgeResolveDefaultModeSync(
  config: BridgeProjectConfig,
): string {
  return invokeBridgeSync<string>({
    op: "project_resolve_default_mode",
    config,
  });
}

// ---------------------------------------------------------------------------
// Frontmatter
// ---------------------------------------------------------------------------

export function bridgeParseFrontmatter(content: string): {
  frontmatter: Record<string, string | string[]>;
  body: string;
} {
  return invokeBridgeSync<{ frontmatter: Record<string, string | string[]>; body: string }>({
    op: "frontmatter_parse",
    content,
  });
}

export function bridgeFrontmatterString(
  value: string | string[] | undefined,
): string | undefined {
  return invokeBridgeSync<string | undefined>({
    op: "frontmatter_string",
    value,
  });
}

export function bridgeFrontmatterStringList(
  value: string | string[] | undefined,
): string[] {
  return invokeBridgeSync<string[]>({
    op: "frontmatter_string_list",
    value,
  });
}

// ---------------------------------------------------------------------------
// File mention parser
// ---------------------------------------------------------------------------

export interface BridgeFileMention {
  rawText: string;
  filePath: string;
  startIndex: number;
  endIndex: number;
  lineRange: { start: number; end?: number } | null;
}

export function bridgeParseFileMentions(input: string): BridgeFileMention[] {
  return invokeBridgeSync<BridgeFileMention[]>({
    op: "parse_file_mentions",
    input,
  });
}

export function bridgeParseLineRange(
  rangeStr: string,
): { start: number; end?: number } | null {
  return invokeBridgeSync<{ start: number; end?: number } | null>({
    op: "parse_line_range",
    rangeStr,
  });
}

export function bridgeIsValidFilePath(filePath: string): boolean {
  return invokeBridgeSync<boolean>({ op: "is_valid_file_path", filePath });
}

export function bridgeParseMentionToken(raw: string): {
  path: string;
  startLine?: number;
  endLine?: number;
} {
  return invokeBridgeSync<{ path: string; startLine?: number; endLine?: number }>({
    op: "parse_mention_token",
    raw,
  });
}

export function bridgeGetCurrentFileMention(
  input: string,
  cursorPosition?: number,
): { mention: string; start: number; end: number; rangeSuffix: string } | null {
  return invokeBridgeSync<{
    mention: string;
    start: number;
    end: number;
    rangeSuffix: string;
  } | null>({
    op: "get_current_file_mention",
    input,
    cursorPosition,
  });
}

// ---------------------------------------------------------------------------
// Context usage
// ---------------------------------------------------------------------------

export function bridgeEstimateTokens(text: string): number {
  return invokeBridgeSync<number>({ op: "estimate_tokens", text });
}

export function bridgeEstimateMessagesTokens(messages: unknown[]): number {
  return invokeBridgeSync<number>({ op: "estimate_messages_tokens", messages });
}

export function bridgeGetContextMax(
  contextWindow?: number | null,
  override?: number | null,
): number {
  return invokeBridgeSync<number>({
    op: "get_context_max",
    contextWindow: contextWindow ?? undefined,
    override: override ?? undefined,
  });
}

export function bridgeComputeContextUsage(options: {
  messages: unknown[];
  systemPrompt?: string;
  contextWindow?: number | null;
  contextMaxOverride?: number | null;
}): { used: number; max: number; percent: number; systemPromptTokens: number; messageTokens: number } {
  return invokeBridgeSync<{
    used: number;
    max: number;
    percent: number;
    systemPromptTokens: number;
    messageTokens: number;
  }>({
    op: "compute_context_usage",
    messages: options.messages,
    systemPrompt: options.systemPrompt ?? "",
    contextWindow: options.contextWindow ?? undefined,
    contextMaxOverride: options.contextMaxOverride ?? undefined,
  });
}

export function bridgeFormatUsageLine(
  usage: Record<string, unknown>,
): string {
  return invokeBridgeSync<string>({ op: "format_usage_line", usage });
}

// ---------------------------------------------------------------------------
// Tasks
// ---------------------------------------------------------------------------

export interface BridgeTask {
  id: string;
  title: string;
  description?: string | null;
  status: string;
  createdAt: string;
  updatedAt: string;
  completedAt?: string | null;
}

export function bridgeLoadTasks(cwd: string): BridgeTask[] {
  return invokeBridgeSync<BridgeTask[]>({ op: "tasks_load", cwd });
}

export function bridgeSaveTasks(cwd: string, tasks: BridgeTask[]): void {
  invokeBridgeSync<boolean>({ op: "tasks_save", cwd, tasks });
}

export function bridgeClearTasks(cwd: string): void {
  invokeBridgeSync<boolean>({ op: "tasks_clear", cwd });
}

export function bridgeAddTask(
  cwd: string,
  title: string,
  description?: string,
): BridgeTask {
  return invokeBridgeSync<BridgeTask>({
    op: "tasks_add",
    cwd,
    title,
    description,
  });
}

export function bridgeRemoveTaskByIndex(
  cwd: string,
  index: number,
): BridgeTask | null {
  return invokeBridgeSync<BridgeTask | null>({
    op: "tasks_remove_by_index",
    cwd,
    index,
  });
}

export function bridgeRemoveTaskById(
  cwd: string,
  id: string,
): BridgeTask | null {
  return invokeBridgeSync<BridgeTask | null>({
    op: "tasks_remove_by_id",
    cwd,
    id,
  });
}

export function bridgeUpdateTasks(
  cwd: string,
  updates: Array<{ id: string; status?: string; title?: string; description?: string }>,
): BridgeTask[] {
  return invokeBridgeSync<BridgeTask[]>({ op: "tasks_update", cwd, updates });
}

export function bridgeTaskCounts(
  tasks: BridgeTask[],
): { pending: number; in_progress: number; completed: number } {
  return invokeBridgeSync<{ pending: number; in_progress: number; completed: number }>({
    op: "tasks_counts",
    tasks,
  });
}

export function bridgeFormatTaskLine(task: BridgeTask): string {
  return invokeBridgeSync<string>({ op: "tasks_format_line", task });
}

export function bridgeFormatTasksList(
  tasks: BridgeTask[],
  title?: string,
): string {
  return invokeBridgeSync<string>({
    op: "tasks_format_list",
    tasks,
    title: title ?? "Tasks",
  });
}

export function bridgeTasksPath(cwd: string): string {
  return invokeBridgeSync<string>({ op: "tasks_path", cwd });
}

export function bridgeGenerateTaskId(): string {
  return invokeBridgeSync<string>({ op: "tasks_generate_id" });
}

// ---------------------------------------------------------------------------
// Custom commands
// ---------------------------------------------------------------------------

export function bridgeLoadCustomCommands(
  cwd: string,
): Array<{
  name: string;
  description: string;
  aliases: string[];
  parameters: string[];
  body: string;
  filePath: string;
}> {
  return invokeBridgeSync<Array<{
    name: string;
    description: string;
    aliases: string[];
    parameters: string[];
    body: string;
    filePath: string;
  }>>({ op: "custom_commands_load", cwd });
}

export function bridgeExpandCommandTemplate(
  template: string,
  command: string,
  args: string[],
  parameters: string[],
  cwd: string,
): string {
  return invokeBridgeSync<string>({
    op: "custom_commands_expand_template",
    template,
    command,
    args,
    parameters,
    cwd,
  });
}

export function bridgeResolveCustomCommandInput(
  input: string,
  commands: Array<{ name: string; aliases: string[] }>,
): { command: Record<string, unknown>; args: string[] } | null {
  return invokeBridgeSync<{ command: Record<string, unknown>; args: string[] } | null>({
    op: "custom_commands_resolve_input",
    input,
    commands,
  });
}

export function bridgeTryExpandSlashCommand(
  text: string,
  cwd: string,
): string | null {
  return invokeBridgeSync<string | null>({
    op: "custom_commands_try_expand",
    text,
    cwd,
  });
}

export function bridgeFormatCustomCommandCatalog(cwd: string): string {
  return invokeBridgeSync<string>({ op: "custom_commands_catalog", cwd });
}

export function bridgeCustomCommandSlashNames(cwd: string): string[] {
  return invokeBridgeSync<string[]>({ op: "custom_commands_slash_names", cwd });
}

// ---------------------------------------------------------------------------
// Dev mode
// ---------------------------------------------------------------------------

export function bridgeIsReadOnlyMode(mode: string): boolean {
  return invokeBridgeSync<boolean>({ op: "dev_mode_is_read_only", mode });
}

export function bridgeIsToolBlockedInReadOnlyMode(toolName: string): boolean {
  return invokeBridgeSync<boolean>({ op: "dev_mode_is_tool_blocked", toolName });
}

export function bridgeCycleMode(current: string): string {
  return invokeBridgeSync<string>({ op: "dev_mode_cycle", current });
}

export function bridgeParseModeFlag(
  args: string[],
): string | { error: string } | undefined {
  return invokeBridgeSync<string | { error: string } | undefined>({
    op: "dev_mode_parse_flag",
    args,
  });
}

export function bridgeSystemPromptForMode(
  basePrompt: string,
  mode: string,
): string {
  return invokeBridgeSync<string>({
    op: "dev_mode_system_prompt",
    basePrompt,
    mode,
  });
}

export function bridgeIsDestructiveBash(cmd: string): boolean {
  return invokeBridgeSync<boolean>({ op: "dev_mode_is_destructive_bash", cmd });
}

export function bridgeShouldAutoApprove(
  mode: string,
  toolName: string,
  params: Record<string, unknown>,
): boolean {
  return invokeBridgeSync<boolean>({
    op: "dev_mode_should_auto_approve",
    mode,
    toolName,
    params,
  });
}

export function bridgeReadOnlyModeBlockReason(
  toolName: string,
  mode: string,
): string {
  return invokeBridgeSync<string>({
    op: "dev_mode_block_reason",
    toolName,
    mode,
  });
}

export function bridgeGetBlockedTools(): string[] {
  return invokeBridgeSync<string[]>({ op: "dev_mode_blocked_tools" });
}

// ---------------------------------------------------------------------------
// Agent/workflow helpers
// ---------------------------------------------------------------------------

export function bridgeLoadSystemPromptBase(cwd: string, explicit?: string): string {
  return invokeBridgeSync<string>({
    op: "agent_load_system_prompt_base",
    cwd,
    explicit,
  });
}

export function bridgeFormatSkillCommandCatalog(
  skills: Array<{ name: string; description: string; source: string }>,
): string {
  return invokeBridgeSync<string>({
    op: "workflow_format_skill_command_catalog",
    skills,
  });
}

export function bridgeToolOutputMaxBytes(): number {
  return invokeBridgeSync<number>({ op: "tool_output_max_bytes" });
}

export function bridgeTruncateToolOutput(text: string, maxBytes?: number): string {
  return invokeBridgeSync<string>({
    op: "tool_output_truncate",
    text,
    maxBytes,
  });
}

export function bridgeTruncateToolPayload(value: unknown): string | undefined {
  return invokeBridgeSync<string | undefined>({
    op: "tool_output_truncate_payload",
    value,
  });
}

// ---------------------------------------------------------------------------
// Overlay rows
// ---------------------------------------------------------------------------

export function bridgeTaskStatusIcon(status: string): string {
  return invokeBridgeSync<string>({ op: "overlay_task_status_icon", status });
}

export function bridgeFormatTaskOverlayRow(
  task: Record<string, unknown>,
  index: number,
): string {
  return invokeBridgeSync<string>({ op: "overlay_format_task_row", task, index });
}

export function bridgeFormatTasksOverlayHeader(
  tasks: Array<Record<string, unknown>>,
): string {
  return invokeBridgeSync<string>({ op: "overlay_format_tasks_header", tasks });
}

// ---------------------------------------------------------------------------
// Checkpoints
// ---------------------------------------------------------------------------

export function bridgeCheckpointsDir(cwd: string): string {
  return invokeBridgeSync<string>({ op: "checkpoints_dir", cwd });
}

export function bridgeValidateCheckpointName(name: string): {
  valid: boolean;
  error?: string;
} {
  return invokeBridgeSync<{ valid: boolean; error?: string }>({
    op: "checkpoint_validate_name",
    name,
  });
}

export function bridgeGetModifiedFiles(cwd: string): string[] {
  return invokeBridgeSync<string[]>({ op: "checkpoint_get_modified_files", cwd });
}

export function bridgeCreateCheckpoint(options: {
  cwd: string;
  messages: unknown[];
  provider: string;
  model: string;
  name?: string;
  modifiedFiles?: string[];
}): Record<string, unknown> {
  return invokeBridgeSync<Record<string, unknown>>({
    op: "checkpoint_create",
    cwd: options.cwd,
    messages: options.messages,
    provider: options.provider,
    model: options.model,
    name: options.name,
    modifiedFiles: options.modifiedFiles,
  });
}

export function bridgeLoadCheckpoint(
  cwd: string,
  name: string,
): {
  metadata: Record<string, unknown>;
  conversation: Record<string, unknown>;
  fileSnapshots: Record<string, string>;
} {
  return invokeBridgeSync<{
    metadata: Record<string, unknown>;
    conversation: Record<string, unknown>;
    fileSnapshots: Record<string, string>;
  }>({ op: "checkpoint_load", cwd, name });
}

export function bridgeListCheckpoints(
  cwd: string,
): Array<{ name: string; metadata: Record<string, unknown>; sizeBytes?: number }> {
  return invokeBridgeSync<
    Array<{ name: string; metadata: Record<string, unknown>; sizeBytes?: number }>
  >({ op: "checkpoint_list", cwd });
}

export function bridgeDeleteCheckpoint(cwd: string, name: string): void {
  invokeBridgeSync<boolean>({ op: "checkpoint_delete", cwd, name });
}

export function bridgeRestoreCheckpointFiles(
  cwd: string,
  snapshots: Record<string, string>,
): void {
  invokeBridgeSync<boolean>({
    op: "checkpoint_restore_files",
    cwd,
    snapshots,
  });
}

export function bridgeFormatRelativeTime(timestamp: string): string {
  return invokeBridgeSync<string>({ op: "checkpoint_format_relative_time", timestamp });
}

export function bridgeFormatCheckpointOverlayRow(
  item: Record<string, unknown>,
): string {
  return invokeBridgeSync<string>({
    op: "checkpoint_format_overlay_row",
    item,
  });
}

export function bridgeFormatCheckpointList(
  items: Array<Record<string, unknown>>,
): string {
  return invokeBridgeSync<string>({ op: "checkpoint_format_list", items });
}

function workflowRoot(packageRoot?: string): Record<string, unknown> {
  return packageRoot ? { packageRoot } : {};
}

export function bridgeLoadSkillContent(skillDir: string, packageRoot?: string): string {
  return invokeBridgeSync<string>({
    op: "workflows_load_skill",
    skillDir,
    ...workflowRoot(packageRoot),
  });
}

export function bridgeRenderPromptTemplate(
  name: string,
  vars: Record<string, string>,
  packageRoot?: string,
): string {
  return invokeBridgeSync<string>({
    op: "workflows_render_prompt",
    name,
    vars,
    ...workflowRoot(packageRoot),
  });
}

export function bridgeBuildOspPrompt(description: string, packageRoot?: string): string {
  return invokeBridgeSync<string>({
    op: "workflows_build_osp",
    description,
    ...workflowRoot(packageRoot),
  });
}

export function bridgeBuildConvertPythonPrompt(path: string, packageRoot?: string): string {
  return invokeBridgeSync<string>({
    op: "workflows_build_convert_python",
    path,
    ...workflowRoot(packageRoot),
  });
}

export function bridgeBuildIdiomReviewPrompt(paths: string[], packageRoot?: string): string {
  return invokeBridgeSync<string>({
    op: "workflows_build_idiom_review",
    paths,
    ...workflowRoot(packageRoot),
  });
}

export function bridgeBuildExplainPrompt(
  mode: string,
  args: string,
  packageRoot?: string,
): string {
  return invokeBridgeSync<string>({
    op: "workflows_build_explain",
    mode,
    args,
    ...workflowRoot(packageRoot),
  });
}

export function bridgeBuildDiagramToModelPrompt(
  source: string,
  content: string,
  packageRoot?: string,
): string {
  return invokeBridgeSync<string>({
    op: "workflows_build_diagram",
    source,
    content,
    ...workflowRoot(packageRoot),
  });
}

function normalizeDiagnostic(d: JacDiagnostic): JacDiagnostic {
  return {
    file: d.file,
    line: d.line,
    column: d.column,
    severity: d.severity,
    code: d.code || undefined,
    message: d.message,
    raw: d.raw,
  };
}
