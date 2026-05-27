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
// Session permissions
// ---------------------------------------------------------------------------

export function bridgeMatchPattern(resource: string, pattern: string, type?: string): boolean {
  return invokeBridgeSync<boolean>({ op: "permissions_match_pattern", resource, pattern, type });
}

export function bridgeEvaluatePermissionPatterns(
  patterns: Array<Record<string, unknown>>,
  toolName: string,
  resource: string,
): string | null {
  return invokeBridgeSync<string | null>({
    op: "permissions_evaluate",
    patterns,
    toolName,
    resource,
  });
}

export function bridgeLoadAlwaysAllowTools(
  cwd: string,
  projectConfig?: Record<string, unknown>,
): string[] {
  return invokeBridgeSync<string[]>({
    op: "permissions_load_always_allow",
    cwd,
    projectConfig,
  });
}

export function bridgeLoadPermissionPatterns(
  projectConfig?: Record<string, unknown>,
): Array<Record<string, unknown>> {
  return invokeBridgeSync<Array<Record<string, unknown>>>({
    op: "permissions_load_patterns",
    projectConfig,
  });
}

export function bridgeNeedsToolApproval(opts: {
  mode: string;
  toolName: string;
  params: Record<string, unknown>;
  sessionGranted?: string[];
  sessionPatternGrants?: Array<Record<string, unknown>>;
  alwaysAllow?: string[];
  permissionPatterns?: Array<Record<string, unknown>>;
  resource?: string;
}): boolean {
  return invokeBridgeSync<boolean>({ op: "permissions_needs_approval", ...opts });
}

// ---------------------------------------------------------------------------
// Context input
// ---------------------------------------------------------------------------

export function bridgeExpandContextInput(cwd: string, text: string): string {
  return invokeBridgeSync<string>({ op: "context_expand_input", cwd, text });
}

export function bridgeLoadFileSlice(
  cwd: string,
  mention: string,
  lineRange?: { start: number; end?: number },
): { block: string; chars: number } {
  return invokeBridgeSync<{ block: string; chars: number }>({
    op: "context_load_file_slice",
    cwd,
    mention,
    lineRange,
  });
}

export function bridgeRunInlineCommand(cwd: string, command: string): string {
  return invokeBridgeSync<string>({ op: "context_run_inline_command", cwd, command });
}

// ---------------------------------------------------------------------------
// Approval display
// ---------------------------------------------------------------------------

export function bridgeFormatApprovalDisplay(
  toolName: string,
  params: Record<string, unknown>,
  subagentName?: string,
): {
  headline: string;
  question: string;
  detailLines: string[];
  previewLines: Array<{ text: string; tone?: string }>;
} {
  return invokeBridgeSync({
    op: "approval_display_format",
    toolName,
    params,
    subagentName,
  });
}

// ---------------------------------------------------------------------------
// Completions
// ---------------------------------------------------------------------------

export function bridgeGetSuggestions(opts: {
  inputText: string;
  authStepKind?: string;
  providers?: string[];
  models?: string[];
  authOptions?: string[];
  filePaths?: string[];
  customCommands?: string[];
  cursorPosition?: number;
}): Array<{ label: string; value: string }> {
  return invokeBridgeSync<Array<{ label: string; value: string }>>({
    op: "completions_get_suggestions",
    ...opts,
  });
}

// ---------------------------------------------------------------------------
// Mermaid render
// ---------------------------------------------------------------------------

export function bridgeRenderMermaid(source: string): string {
  return invokeBridgeSync<string>({ op: "mermaid_render", source });
}

export function bridgeDetectDiagramType(source: string): string {
  return invokeBridgeSync<string>({ op: "mermaid_detect_type", source });
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

// ---------------------------------------------------------------------------
// Skills bridge
// ---------------------------------------------------------------------------

export interface BridgeSkill {
  name: string;
  description: string;
  filePath: string;
  baseDir: string;
  source: string;
  disableModelInvocation: boolean;
}

export interface BridgeSkillDiagnostic {
  type: "warning" | "collision";
  message: string;
  path: string;
  collision?: {
    name: string;
    winnerPath: string;
    loserPath: string;
  };
}

export interface BridgeLoadSkillsResult {
  skills: BridgeSkill[];
  diagnostics: BridgeSkillDiagnostic[];
}

export function bridgeLoadSkillsFromDir(
  dir: string,
  source: string,
): BridgeLoadSkillsResult {
  return invokeBridgeSync<BridgeLoadSkillsResult>({
    op: "skills_load_from_dir",
    dir,
    source,
  });
}

export function bridgeLoadJackalSkills(options?: {
  cwd?: string;
  packageRoot?: string;
  agentDir?: string;
  skillPaths?: string[];
  includeDefaults?: boolean;
}): BridgeLoadSkillsResult {
  return invokeBridgeSync<BridgeLoadSkillsResult>({
    op: "skills_load_jackal",
    cwd: options?.cwd,
    packageRoot: options?.packageRoot,
    agentDir: options?.agentDir,
    skillPaths: options?.skillPaths,
    includeDefaults: options?.includeDefaults,
  });
}

export function bridgeFormatSkillsForPrompt(skills: BridgeSkill[]): string {
  return invokeBridgeSync<string>({
    op: "skills_format_for_prompt",
    skills,
  });
}

export function bridgeAppendSkillsToPrompt(
  systemPrompt: string,
  skills: BridgeSkill[],
): string {
  return invokeBridgeSync<string>({
    op: "skills_append_to_prompt",
    systemPrompt,
    skills,
  });
}

export function bridgeExpandSkillCommand(
  text: string,
  skills: BridgeSkill[],
): string {
  return invokeBridgeSync<string>({
    op: "skills_expand_command",
    text,
    skills,
  });
}

export function bridgeLoadSkillByDir(
  dirName: string,
  packageRoot?: string,
): string {
  return invokeBridgeSync<string>({
    op: "skills_load_by_dir",
    dirName,
    packageRoot,
  });
}

export function bridgeSkillReadAllowlist(
  skills: BridgeSkill[],
): { files: string[]; roots: string[] } {
  return invokeBridgeSync<{ files: string[]; roots: string[] }>({
    op: "skills_read_allowlist",
    skills,
  });
}

// ---------------------------------------------------------------------------
// Project init bridge
// ---------------------------------------------------------------------------

export interface BridgeProjectInfo {
  projectName: string;
  description: string;
  hasJacToml: boolean;
  jacTomlEntry: string | null;
  jacVersion: string | null;
  pythonVersion: string | null;
  jacFiles: string[];
  pythonFiles: string[];
  hasVenv: boolean;
  hasGit: boolean;
  hasTests: boolean;
  hasReadme: boolean;
  hasAgentsMd: boolean;
  hasJackalConfig: boolean;
  npmDeps: string[];
  projectType: string;
}

export function bridgeAnalyzeProject(cwd: string): BridgeProjectInfo {
  return invokeBridgeSync<BridgeProjectInfo>({
    op: "project_init_analyze",
    cwd,
  });
}

export function bridgeGenerateAgentsMd(info: BridgeProjectInfo): string {
  return invokeBridgeSync<string>({
    op: "project_init_generate_agents_md",
    info,
  });
}

export function bridgeRunProjectInit(
  cwd: string,
  options?: { force?: boolean; lean?: boolean },
): { written: boolean; path: string; content: string } {
  return invokeBridgeSync<{ written: boolean; path: string; content: string }>({
    op: "project_init_run",
    cwd,
    force: options?.force,
    lean: options?.lean,
  });
}

// ---------------------------------------------------------------------------
// MCP schema bridge
// ---------------------------------------------------------------------------

export function bridgeMcpSchemaToParameters(
  schema?: Record<string, unknown>,
): Record<string, unknown> {
  return invokeBridgeSync<Record<string, unknown>>({
    op: "mcp_schema_to_parameters",
    schema,
  });
}

export function bridgeMcpCoerceBySchema(
  value: unknown,
  schema: Record<string, unknown>,
): unknown {
  return invokeBridgeSync<unknown>({
    op: "mcp_coerce_by_schema",
    value,
    schema,
  });
}

export function bridgeMcpValidateAndCoerce(
  schema: Record<string, unknown> | undefined,
  raw: Record<string, unknown>,
): Record<string, unknown> {
  return invokeBridgeSync<Record<string, unknown>>({
    op: "mcp_validate_and_coerce",
    schema,
    raw,
  });
}

// ---------------------------------------------------------------------------
// Task tools bridge
// ---------------------------------------------------------------------------

export function bridgeTaskToolsBuildCreate(
  cwd: string,
  inputs: Array<{ title: string; description?: string }>,
): { text: string; created: BridgeTask[]; all: BridgeTask[] } {
  return invokeBridgeSync<{ text: string; created: BridgeTask[]; all: BridgeTask[] }>({
    op: "task_tools_build_create",
    cwd,
    inputs,
  });
}

export function bridgeTaskToolsBuildUpdate(
  cwd: string,
  updates: Array<Record<string, unknown>>,
): { text: string; all: BridgeTask[] } {
  return invokeBridgeSync<{ text: string; all: BridgeTask[] }>({
    op: "task_tools_build_update",
    cwd,
    updates,
  });
}

export function bridgeTaskToolsBuildList(
  cwd: string,
  status?: string,
): { text: string; tasks: BridgeTask[]; all: BridgeTask[] } {
  return invokeBridgeSync<{ text: string; tasks: BridgeTask[]; all: BridgeTask[] }>({
    op: "task_tools_build_list",
    cwd,
    status,
  });
}

export function bridgeTaskToolsBuildDelete(
  cwd: string,
  params: Record<string, unknown>,
): { text: string; deleted?: string[]; remaining: BridgeTask[]; cleared?: number } {
  return invokeBridgeSync<{ text: string; deleted?: string[]; remaining: BridgeTask[]; cleared?: number }>({
    op: "task_tools_build_delete",
    cwd,
    params,
  });
}

// ---------------------------------------------------------------------------
// Web tools bridge
// ---------------------------------------------------------------------------

export function bridgeWebBraveApiKey(): string | undefined {
  return invokeBridgeSync<string | undefined>({
    op: "web_brave_api_key",
  });
}

export function bridgeWebAssertSafeUrl(url: string): boolean {
  return invokeBridgeSync<boolean>({
    op: "web_assert_safe_url",
    url,
  });
}

export function bridgeWebHtmlToText(html: string): string {
  return invokeBridgeSync<string>({
    op: "web_html_to_text",
    html,
  });
}

export function bridgeWebFormatSearchResults(
  results: Array<{ title: string; url: string; description: string }>,
): string {
  return invokeBridgeSync<string>({
    op: "web_format_search_results",
    results,
  });
}

export interface BridgeWebSearchResult {
  title: string;
  url: string;
  description: string;
}

export function bridgeWebSearch(
  query: string,
  count?: number,
): { results: BridgeWebSearchResult[]; raw?: unknown } {
  return invokeBridgeSync<{ results: BridgeWebSearchResult[]; raw?: unknown }>({
    op: "web_search",
    query,
    count,
  });
}

export interface BridgeWebFetchResult {
  url: string;
  contentType: string;
  text: string;
}

export function bridgeWebFetch(
  url: string,
  timeout?: number,
): BridgeWebFetchResult {
  return invokeBridgeSync<BridgeWebFetchResult>({
    op: "web_fetch",
    url,
    timeout,
  });
}

// ── Core: tool summary ──────────────────────────────────────────────

export function bridgeToolSummaryNormalizeInput(
  raw: unknown,
): Record<string, unknown> | undefined {
  return invokeBridgeSync<Record<string, unknown> | undefined>({
    op: "tool_summary_normalize_input",
    raw,
  });
}

export function bridgeToolSummaryFormat(
  toolName: string,
  input?: Record<string, unknown>,
): string {
  return invokeBridgeSync<string>({
    op: "tool_summary_format",
    toolName,
    input,
  });
}

export function bridgeToolSummaryFilePath(
  input?: Record<string, unknown>,
): string {
  return invokeBridgeSync<string>({ op: "tool_summary_file_path", input });
}

export function bridgeToolSummaryBashCommand(
  input?: Record<string, unknown>,
): string {
  return invokeBridgeSync<string>({ op: "tool_summary_bash_command", input });
}

export function bridgeToolSummaryEnrich(
  toolName: string,
  input: Record<string, unknown> | undefined,
  result: unknown,
): Record<string, unknown> | undefined {
  return invokeBridgeSync<Record<string, unknown> | undefined>({
    op: "tool_summary_enrich",
    toolName,
    input,
    result,
  });
}

export function bridgeToolSummaryEventInput(
  event: Record<string, unknown>,
): Record<string, unknown> | undefined {
  return invokeBridgeSync<Record<string, unknown> | undefined>({
    op: "tool_summary_event_input",
    event,
  });
}

// ── Session: auto-compact ──────────────────────────────────────────

export interface AutoCompactConfig {
  enabled: boolean;
  thresholdPercent: number;
  keepTail: number;
  notify: boolean;
  strategy: "llm" | "mechanical";
}

export function bridgeAutoCompactResolveConfig(raw: {
  autoCompact?: boolean | Partial<AutoCompactConfig>;
  compactStrategy?: "llm" | "mechanical";
}): AutoCompactConfig {
  return invokeBridgeSync<AutoCompactConfig>({
    op: "auto_compact_resolve_config",
    raw,
  });
}

export function bridgeAutoCompactShouldTrigger(
  usagePercent: number,
  config: AutoCompactConfig,
): boolean {
  return invokeBridgeSync<boolean>({
    op: "auto_compact_should_trigger",
    usagePercent,
    config,
  });
}

export function bridgeAutoCompactBuildMechanicalSummary(
  messages: Record<string, unknown>[],
): string {
  return invokeBridgeSync<string>({
    op: "auto_compact_build_mechanical_summary",
    messages,
  });
}

export function bridgeAutoCompactBuildLlmPrompt(
  messages: Record<string, unknown>[],
): string {
  return invokeBridgeSync<string>({
    op: "auto_compact_build_llm_prompt",
    messages,
  });
}

// ── Session: index / persistence ───────────────────────────────────

export interface SessionIndexEntry {
  id: string;
  name: string;
  cwd: string;
  updatedAt: string;
  messageCount: number;
  model?: { provider: string; id: string };
}

export interface SessionRecord {
  sessionId: string;
  sessionName: string;
  cwd: string;
  createdAt: string;
  updatedAt: string;
  model?: { provider: string; id: string };
  messages: unknown[];
}

export function bridgeSessionList(
  sessionDir: string,
  options?: { cwd?: string },
): SessionIndexEntry[] {
  return invokeBridgeSync<SessionIndexEntry[]>({
    op: "session_list",
    sessionDir,
    options,
  });
}

export function bridgeSessionLoad(
  sessionDir: string,
  id: string,
): SessionRecord | null {
  return invokeBridgeSync<SessionRecord | null>({
    op: "session_load",
    sessionDir,
    id,
  });
}

export function bridgeSessionSave(
  sessionDir: string,
  record: SessionRecord,
): boolean {
  return invokeBridgeSync<boolean>({
    op: "session_save",
    sessionDir,
    record,
  });
}

export function bridgeSessionDelete(
  sessionDir: string,
  id: string,
): boolean {
  return invokeBridgeSync<boolean>({
    op: "session_delete",
    sessionDir,
    id,
  });
}

export function bridgeSessionLast(
  sessionDir: string,
  options?: { cwd?: string },
): SessionIndexEntry | null {
  return invokeBridgeSync<SessionIndexEntry | null>({
    op: "session_last",
    sessionDir,
    options,
  });
}

export function bridgeSessionResolveTarget(
  sessionDir: string,
  target: string,
  options?: { cwd?: string },
): SessionRecord | null {
  return invokeBridgeSync<SessionRecord | null>({
    op: "session_resolve_target",
    sessionDir,
    target,
    options,
  });
}

export function bridgeSessionPrune(
  sessionDir: string,
  options?: { maxCount?: number; retentionDays?: number },
): string[] {
  return invokeBridgeSync<string[]>({
    op: "session_prune",
    sessionDir,
    options,
  });
}

export function bridgeSessionMigrateLegacy(
  sessionDir: string,
  cwd: string,
): SessionRecord | null {
  return invokeBridgeSync<SessionRecord | null>({
    op: "session_migrate_legacy",
    sessionDir,
    cwd,
  });
}

export function bridgeSessionRebuildIndex(sessionDir: string): SessionIndexEntry[] {
  return invokeBridgeSync<SessionIndexEntry[]>({
    op: "session_rebuild_index",
    sessionDir,
  });
}

export function bridgeSessionIsValidId(id: string): boolean {
  return invokeBridgeSync<boolean>({ op: "session_is_valid_id", id });
}

// ── Session: persistence helpers ──────────────────────────────────

export function bridgeSessionDirPath(cwd: string, subdir?: string): string {
  return invokeBridgeSync<string>({ op: "session_dir_path", cwd, subdir });
}

export function bridgeSessionExportMarkdown(opts: {
  sessionId: string;
  sessionName: string;
  cwd: string;
  modelRef?: { provider: string; id: string } | null;
  messages: Record<string, unknown>[];
}): string {
  return invokeBridgeSync<string>({
    op: "session_export_markdown",
    sessionId: opts.sessionId,
    sessionName: opts.sessionName,
    cwd: opts.cwd,
    modelRef: opts.modelRef ?? null,
    messages: opts.messages,
  });
}

export function bridgeSessionSaveCompactionBackup(
  sessionDir: string,
  sessionId: string,
  messages: Record<string, unknown>[],
): boolean {
  return invokeBridgeSync<boolean>({
    op: "session_save_compaction_backup",
    sessionDir,
    sessionId,
    messages,
  });
}

export function bridgeSessionLoadCompactionBackup(
  sessionDir: string,
  sessionId: string,
): Record<string, unknown>[] | null {
  return invokeBridgeSync<Record<string, unknown>[] | null>({
    op: "session_load_compaction_backup",
    sessionDir,
    sessionId,
  });
}

export function bridgeSessionClearCompactionBackup(
  sessionDir: string,
  sessionId: string,
): boolean {
  return invokeBridgeSync<boolean>({
    op: "session_clear_compaction_backup",
    sessionDir,
    sessionId,
  });
}

export function bridgeSessionFlushRecord(opts: {
  sessionDir: string;
  sessionId: string;
  sessionName: string;
  cwd: string;
  createdAt: string;
  messages: Record<string, unknown>[];
  modelRef?: { provider: string; id: string } | null;
}): boolean {
  return invokeBridgeSync<boolean>({
    op: "session_flush_record",
    sessionDir: opts.sessionDir,
    sessionId: opts.sessionId,
    sessionName: opts.sessionName,
    cwd: opts.cwd,
    createdAt: opts.createdAt,
    messages: opts.messages,
    modelRef: opts.modelRef ?? null,
  });
}

// ── Auth: flow state machine ───────────────────────────────────────

export interface AuthProviderEntry {
  id: string;
  displayName: string;
  authType: "oauth" | "api_key" | "env";
  configured: boolean;
  modelCount: number;
}

export interface AuthModelEntry {
  provider: string;
  modelId: string;
  displayName: string;
}

export interface AuthFlowState {
  step: Record<string, unknown>;
}

export function bridgeAuthValidateProvider(
  entry: unknown,
): AuthProviderEntry | null {
  return invokeBridgeSync<AuthProviderEntry | null>({
    op: "auth_validate_provider", entry,
  });
}

export function bridgeAuthValidateModel(
  entry: unknown,
): AuthModelEntry | null {
  return invokeBridgeSync<AuthModelEntry | null>({
    op: "auth_validate_model", entry,
  });
}

export function bridgeAuthFilterProviders(
  providers: AuthProviderEntry[],
  query: string,
): AuthProviderEntry[] {
  return invokeBridgeSync<AuthProviderEntry[]>({
    op: "auth_filter_providers", providers, query,
  });
}

export function bridgeAuthFilterModels(
  models: AuthModelEntry[],
  query: string,
  providerFilter?: string,
): AuthModelEntry[] {
  return invokeBridgeSync<AuthModelEntry[]>({
    op: "auth_filter_models", models, query, providerFilter,
  });
}

export function bridgeAuthFormatProviderLabel(
  entry: Record<string, unknown>,
): string {
  return invokeBridgeSync<string>({
    op: "auth_format_provider_label", entry,
  });
}

export function bridgeAuthFormatModelLabel(
  entry: Record<string, unknown>,
): string {
  return invokeBridgeSync<string>({
    op: "auth_format_model_label", entry,
  });
}

export function bridgeAuthInitialState(): AuthFlowState {
  return invokeBridgeSync<AuthFlowState>({ op: "auth_initial_state" });
}

export function bridgeAuthTransition(
  state: AuthFlowState,
  action: string,
  payload?: Record<string, unknown>,
): AuthFlowState {
  return invokeBridgeSync<AuthFlowState>({
    op: "auth_transition", state, action, payload,
  });
}

// ── Orchestration: subagents ──────────────────────────────────────

export interface SubagentDefinition {
  name: string;
  description: string;
  systemPrompt: string;
  tools?: string[];
  model?: string;
  source: "package" | "project";
  filePath: string;
}

export function bridgeSubagentList(cwd: string): SubagentDefinition[] {
  return invokeBridgeSync<SubagentDefinition[]>({ op: "subagent_list", cwd });
}

export function bridgeSubagentGet(cwd: string, name: string): SubagentDefinition | null {
  return invokeBridgeSync<SubagentDefinition | null>({ op: "subagent_get", cwd, name });
}

export function bridgeSubagentFormatCatalog(cwd: string): string {
  return invokeBridgeSync<string>({ op: "subagent_format_catalog", cwd });
}

export function bridgeSubagentSettingsOverrides(): Record<string, string> {
  return invokeBridgeSync<Record<string, string>>({ op: "subagent_settings_overrides" });
}

export function bridgeSubagentProjectOverrides(cwd: string): Record<string, string> {
  return invokeBridgeSync<Record<string, string>>({ op: "subagent_project_overrides", cwd });
}

export function bridgeSubagentNormalizeTools(tools?: string[]): string[] | null {
  return invokeBridgeSync<string[] | null>({ op: "subagent_normalize_tools", tools });
}

export function bridgeSubagentFilterTools(
  allToolNames: string[],
  allowedNames?: Set<string> | null,
): string[] {
  return invokeBridgeSync<string[]>({
    op: "subagent_filter_tools",
    allToolNames,
    allowedNames: allowedNames ? [...allowedNames] : null,
  });
}

// ── Orchestration: chains ─────────────────────────────────────────

export interface ChainStep {
  agent: string;
  task: string;
  output?: string;
  reads?: string[];
  model?: string;
}

export interface ChainDefinition {
  name: string;
  description: string;
  steps: ChainStep[];
  source: "package" | "project";
  filePath: string;
}

export function bridgeChainList(cwd: string): ChainDefinition[] {
  return invokeBridgeSync<ChainDefinition[]>({ op: "chain_list", cwd });
}

export function bridgeChainGet(cwd: string, name: string): ChainDefinition | null {
  return invokeBridgeSync<ChainDefinition | null>({ op: "chain_get", cwd, name });
}

export function bridgeChainFormatCatalog(cwd: string): string {
  return invokeBridgeSync<string>({ op: "chain_format_catalog", cwd });
}

export function bridgeChainDirsExist(cwd: string): boolean {
  return invokeBridgeSync<boolean>({ op: "chain_dirs_exist", cwd });
}

// ── Orchestration: runner helpers ─────────────────────────────────

export function bridgeRunnerExtractSummary(messages: Record<string, unknown>[]): string {
  return invokeBridgeSync<string>({ op: "runner_extract_summary", messages });
}

export function bridgeRunnerCountToolCalls(messages: Record<string, unknown>[]): number {
  return invokeBridgeSync<number>({ op: "runner_count_tool_calls", messages });
}

export function bridgeRunnerBuildStepPrompt(
  step: ChainStep,
  task: string,
  previous: string,
): string {
  return invokeBridgeSync<string>({ op: "runner_build_step_prompt", step, task, previous });
}

export function bridgeRunnerBuildToolDescription(cwd: string): string {
  return invokeBridgeSync<string>({ op: "runner_build_tool_description", cwd });
}

// ── CLI: run helpers ──────────────────────────────────────────────

export function bridgeCliResolveRunMode(cwd: string, cliMode?: string): string {
  return invokeBridgeSync<string>({ op: "cli_resolve_run_mode", cwd, cliMode });
}

export function bridgeCliParseRunArgs(argv: string[]): { ok: true; options: { prompt: string; plain?: boolean; mode?: string } } | { ok: false; error: string } {
  return invokeBridgeSync<{ ok: true; options: { prompt: string; plain?: boolean; mode?: string } } | { ok: false; error: string }>({ op: "cli_parse_run_args", argv });
}

export function bridgeCliFormatToolLine(toolName: string, input?: Record<string, unknown>): string {
  return invokeBridgeSync<string>({ op: "cli_format_tool_line", toolName, input });
}

export function bridgeCliLastAssistantText(messages: { role: string; text: string }[]): string {
  return invokeBridgeSync<string>({ op: "cli_last_assistant_text", messages });
}

export function bridgeCliApprovalMessage(toolName: string, subagentName?: string): string {
  return invokeBridgeSync<string>({ op: "cli_approval_message", toolName, subagentName });
}

// ── Agent: path resolve ──────────────────────────────────────────

export function bridgeSafeResolve(cwd: string, inputPath: string): string {
  return invokeBridgeSync<string>({ op: "path_safe_resolve", cwd, inputPath });
}

export function bridgeResolveReadPath(
  cwd: string,
  inputPath: string,
  allowFiles?: string[],
  allowRoots?: string[],
): string {
  return invokeBridgeSync<string>({ op: "path_resolve_read", cwd, inputPath, allowFiles, allowRoots });
}

export function bridgeFormatPostWriteMessage(action: string, path: string, notes?: string[]): string {
  return invokeBridgeSync<string>({ op: "path_format_post_write", action, path, notes });
}

// ── Core: adapter helpers ────────────────────────────────────────

export function bridgeResolveContextMax(
  cwd: string,
  options?: { contextMax?: number },
  envValue?: string,
  projectConfig?: Record<string, unknown>,
): number | null {
  return invokeBridgeSync<number | null>({ op: "adapter_resolve_context_max", cwd, options, envValue, projectConfig });
}

export function bridgeSessionStorageDir(cwd: string, override?: string): string {
  return invokeBridgeSync<string>({ op: "adapter_session_storage_dir", cwd, override });
}

// ── Core: agent busy ──────────────────────────────────────────────

export function bridgeIsAgentBusy(snapshot: Record<string, unknown>): boolean {
  return invokeBridgeSync<boolean>({ op: "core_is_agent_busy", snapshot });
}

// ── Core: store types / bridge helpers ────────────────────────────

export function bridgeStoreAgentPhases(): string[] {
  return invokeBridgeSync<string[]>({ op: "store_agent_phases" });
}

export function bridgeStoreMaxToolExecutions(): number {
  return invokeBridgeSync<number>({ op: "store_max_tool_executions" });
}

export function bridgeStoreStreamEmitMs(): number {
  return invokeBridgeSync<number>({ op: "store_stream_emit_ms" });
}

export function bridgeStoreInitialSnapshot(): Record<string, unknown> {
  return invokeBridgeSync<Record<string, unknown>>({ op: "store_initial_snapshot" });
}

export function bridgeStoreMessagesToTranscript(messages: { role: string; text: string }[]): { kind: string; text: string }[] {
  return invokeBridgeSync<{ kind: string; text: string }[]>({ op: "store_messages_to_transcript", messages });
}

export function bridgeStoreToolResultDisplayText(value: unknown): string | null {
  return invokeBridgeSync<string | null>({ op: "store_tool_result_display_text", value });
}

export function bridgeStoreFormatToolPayload(value: unknown): string | null {
  return invokeBridgeSync<string | null>({ op: "store_format_tool_payload", value });
}

export function bridgeStoreToolResultStatus(value: unknown, isError?: boolean): "done" | "error" {
  return invokeBridgeSync<"done" | "error">({ op: "store_tool_result_status", value, isError });
}

export function bridgeStoreAgentMessageToStore(message: Record<string, unknown>): { role: string; text: string } | null {
  return invokeBridgeSync<{ role: string; text: string } | null>({ op: "store_agent_message_to_store", message });
}

export function bridgeStoreAgentMessagesToStore(messages: unknown[]): { role: string; text: string }[] {
  return invokeBridgeSync<{ role: string; text: string }[]>({ op: "store_agent_messages_to_store", messages });
}

export function bridgeStoreBuildSeedData(
  mode: string,
  provider: string,
  model: string,
  sessionId: string,
  sessionName: string,
  messages?: unknown[],
): Record<string, unknown> {
  return invokeBridgeSync<Record<string, unknown>>({ op: "store_build_seed_data", mode, provider, model, sessionId, sessionName, messages });
}

// ── Session: LLM compact ─────────────────────────────────────────

export function bridgeWrapCompactionSummary(text: string): string {
  return invokeBridgeSync<string>({ op: "session_wrap_compaction_summary", text });
}

// ── Session: outbound queue ──────────────────────────────────────

export interface OutboundQueueData {
  items: string[];
  length: number;
}

export function bridgeQueueNew(): OutboundQueueData {
  return invokeBridgeSync<OutboundQueueData>({ op: "queue_new" });
}

export function bridgeQueueEnqueue(data: OutboundQueueData, text: string): OutboundQueueData {
  return invokeBridgeSync<OutboundQueueData>({ op: "queue_enqueue", data, text });
}

export function bridgeQueueDequeue(data: OutboundQueueData): { item: string | null; queue: OutboundQueueData } {
  return invokeBridgeSync<{ item: string | null; queue: OutboundQueueData }>({ op: "queue_dequeue", data });
}

export function bridgeQueueClear(data: OutboundQueueData): OutboundQueueData {
  return invokeBridgeSync<OutboundQueueData>({ op: "queue_clear", data });
}

export function bridgeQueueLength(data: OutboundQueueData): number {
  return invokeBridgeSync<number>({ op: "queue_length", data });
}

// ── LSP helpers ───────────────────────────────────────────────────

export interface LspDiagnosticResult {
  file: string;
  line: number;
  column?: number;
  severity: string;
  message: string;
  code?: string | number;
  source?: string;
}

export function bridgeLspParseCheckOutput(output: string, defaultFile?: string): LspDiagnosticResult[] {
  return invokeBridgeSync<LspDiagnosticResult[]>({ op: "lsp_parse_check_output", output, defaultFile });
}

export function bridgeLspExtractSymbol(line: string, character: number): string {
  return invokeBridgeSync<string>({ op: "lsp_extract_symbol", line, character });
}

export function bridgeLspEscapeRegex(str: string): string {
  return invokeBridgeSync<string>({ op: "lsp_escape_regex", str });
}

export function bridgeLspFormatDiagnostics(diagnostics: LspDiagnosticResult[]): string {
  return invokeBridgeSync<string>({ op: "lsp_format_diagnostics", diagnostics });
}

export function bridgeLspFormatHoverInfo(info: Record<string, unknown>): string {
  return invokeBridgeSync<string>({ op: "lsp_format_hover_info", info });
}

export function bridgeLspFormatLocations(locations: Record<string, unknown>[], label?: string): string {
  return invokeBridgeSync<string>({ op: "lsp_format_locations", locations, label });
}

// ── Auth: I/O ────────────────────────────────────────────────────

export function bridgeAuthResolvePath(agentDir?: string): string {
  return invokeBridgeSync<string>({ op: "auth_resolve_path", agentDir });
}

export function bridgeAuthLoadFile(path: string): Record<string, unknown> {
  return invokeBridgeSync<Record<string, unknown>>({ op: "auth_load_file", path });
}

export function bridgeAuthSaveFile(path: string, data: Record<string, unknown>): boolean {
  return invokeBridgeSync<boolean>({ op: "auth_save_file", path, data });
}

export function bridgeAuthGetStatus(
  provider: string,
  storedProviders?: Record<string, unknown>,
  runtimeKeys?: string[],
  envApiKey?: string,
): { configured: boolean; source?: string; label?: string } {
  return invokeBridgeSync<{ configured: boolean; source?: string; label?: string }>({
    op: "auth_get_status", provider, storedProviders, runtimeKeys, envApiKey,
  });
}
