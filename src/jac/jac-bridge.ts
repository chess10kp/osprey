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
