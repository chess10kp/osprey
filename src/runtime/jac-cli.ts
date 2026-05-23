// Unified Jac CLI helpers — host-side check/format/test without MCP round-trip.

import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { accessSync, constants } from "node:fs";
import { join, delimiter } from "node:path";
import type { JacDiagnostic } from "./jac-types.js";

const execFileAsync = promisify(execFile);

export type { JacDiagnostic } from "./jac-types.js";
export { fingerprintErrors } from "./jac-types.js";

export interface JacCommandResult {
  stdout: string;
  stderr: string;
  rawOutput: string;
  exitCode: number;
  diagnostics: JacDiagnostic[];
}

/**
 * Parse the stdout/stderr of `jac check` into structured diagnostics.
 *
 * Supports two output formats:
 * 1. Single-line: `file:line:col: severity: message`
 * 2. Multi-line: `Error: message\n --> file:line:col`
 */
export function parseJacCheckOutput(stdout: string, stderr: string): JacDiagnostic[] {
  const diagnostics: JacDiagnostic[] = [];
  const combined = stdout + "\n" + stderr;
  const lines = combined.split("\n");
  let pending: { severity: JacDiagnostic["severity"]; code?: string; message: string; raw: string } | null = null;

  for (const raw of lines) {
    const stripped = raw.replace(/\x1b\[[0-9;]*m/g, "");
    const trimmed = stripped.trim();
    if (!trimmed) continue;

    const single = trimmed.match(/^(.+?):(\d+):(\d+):\s+(error|warning|info):\s+(.*)$/i);
    if (single) {
      diagnostics.push({
        file: single[1]!,
        line: parseInt(single[2]!, 10),
        column: parseInt(single[3]!, 10),
        severity: single[4]!.toLowerCase() as JacDiagnostic["severity"],
        message: single[5]!,
        raw: trimmed,
      });
      pending = null;
      continue;
    }

    const header = trimmed.match(
      /^(?:[✖✗❌]\s*)?(Error|Warning|Info|Note)(?::\s*(?:(error|warning|info)\[([A-Z0-9]+)\])?)?:?\s*(.*)$/i,
    );
    if (header && /^[✖✗❌]?\s*(Error|Warning|Info|Note)/i.test(trimmed)) {
      pending = {
        severity: (header[2] || header[1])!.toLowerCase() as JacDiagnostic["severity"],
        code: header[3],
        message: (header[4] || "").trim(),
        raw: trimmed,
      };
      continue;
    }

    const loc = trimmed.match(/^-->\s*(.+?):(\d+):(\d+)\s*$/);
    if (loc && pending) {
      diagnostics.push({
        file: loc[1]!,
        line: parseInt(loc[2]!, 10),
        column: parseInt(loc[3]!, 10),
        severity: pending.severity,
        code: pending.code,
        message: pending.message,
        raw: pending.raw,
      });
      pending = null;
    }
  }

  return diagnostics;
}

/** Search PATH for a `jac` or `jaclang` binary. Returns the command name or null. */
export function findJacBinary(): string | null {
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

/** Format an array of diagnostics into a human-readable summary. */
export function formatDiagnostics(diagnostics: JacDiagnostic[]): string {
  return diagnostics
    .map((d) => {
      const col = d.column ? `:${d.column}` : "";
      const code = d.code ? ` [${d.code}]` : "";
      return `- ${d.file}:${d.line}${col} [${d.severity}]${code} ${d.message}`;
    })
    .join("\n");
}

/** Run `jac <args...>` and return normalized output with parsed diagnostics. */
export async function runJacCommand(
  cmd: string[],
  cwd: string,
  options?: { timeoutMs?: number; parseDiagnostics?: boolean },
): Promise<JacCommandResult> {
  const jacBin = findJacBinary();
  if (!jacBin) {
    throw new Error("jac binary not found. Install with: pip install jaclang");
  }
  if (!cmd.length) {
    throw new Error("runJacCommand requires at least one subcommand arg");
  }

  const timeoutMs = options?.timeoutMs ?? 120_000;
  const parseDiagnostics = options?.parseDiagnostics ?? cmd[0] === "check";

  try {
    const { stdout, stderr } = await execFileAsync(jacBin, cmd, { cwd, timeout: timeoutMs });
    const rawOutput = stdout + stderr;
    return {
      stdout,
      stderr,
      rawOutput,
      exitCode: 0,
      diagnostics: parseDiagnostics ? parseJacCheckOutput(stdout, stderr) : [],
    };
  } catch (err: unknown) {
    const e = err as { stdout?: string; stderr?: string; message?: string; code?: number };
    const stdout = e.stdout ?? "";
    const stderr = e.stderr ?? "";
    const rawOutput = stdout + stderr;
    const diagnostics = parseDiagnostics ? parseJacCheckOutput(stdout, stderr) : [];
    const exitCode = typeof e.code === "number" ? e.code : 1;
    if (diagnostics.length === 0 && !rawOutput.trim()) {
      throw new Error(stderr || e.message || "Unknown jac CLI error");
    }
    return { stdout, stderr, rawOutput, exitCode, diagnostics };
  }
}

/** Run `jac check` and return parsed diagnostics plus raw output. */
export async function runJacCheck(
  cwd: string,
  files?: string[],
): Promise<{
  diagnostics: JacDiagnostic[];
  rawOutput: string;
  exitCode: number;
  exitError?: string;
}> {
  const targets = files && files.length > 0 ? files : ["."];
  const args = ["check", ...targets];

  const result = await runJacCommand(args, cwd, { parseDiagnostics: true });
  return {
    diagnostics: result.diagnostics,
    rawOutput: result.rawOutput,
    exitCode: result.exitCode,
    exitError:
      result.diagnostics.length === 0 && result.exitCode !== 0
        ? result.stderr || "jac check failed"
        : undefined,
  };
}

/** Run `jac format` in-place on the given files. Returns true if any file was changed. */
export async function runJacFormat(
  cwd: string,
  files: string[],
): Promise<{ changed: boolean; rawOutput: string; exitCode: number }> {
  if (files.length === 0) {
    return { changed: false, rawOutput: "", exitCode: 0 };
  }

  const result = await runJacCommand(["format", ...files], cwd, { parseDiagnostics: false });
  const combined = result.rawOutput.trim();
  const changed = combined.includes("changed") && !combined.includes("FAILURES");
  return { changed, rawOutput: combined, exitCode: result.exitCode };
}

/** Run `jac test` and return raw output with best-effort diagnostic parsing. */
export async function runJacTest(
  cwd: string,
  files?: string[],
): Promise<{
  passed: boolean;
  rawOutput: string;
  exitCode: number;
  diagnostics: JacDiagnostic[];
}> {
  const args = ["test"];
  if (files && files.length > 0) args.push(...files);

  const result = await runJacCommand(args, cwd, { parseDiagnostics: true, timeoutMs: 300_000 });
  return {
    passed: result.exitCode === 0 && result.diagnostics.filter((d) => d.severity === "error").length === 0,
    rawOutput: result.rawOutput,
    exitCode: result.exitCode,
    diagnostics: result.diagnostics,
  };
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
  const args = ["run", file];
  if (options?.args?.length) args.push(...options.args);

  try {
    const result = await runJacCommand(args, cwd, {
      timeoutMs: options?.timeoutMs ?? 60_000,
      parseDiagnostics: false,
    });
    return {
      stdout: result.stdout,
      stderr: result.stderr,
      exitCode: result.exitCode,
      error: result.exitCode !== 0 ? result.stderr.trim() || "jac run failed" : undefined,
    };
  } catch (err) {
    return {
      stdout: "",
      stderr: String(err),
      exitCode: 1,
      error: err instanceof Error ? err.message : String(err),
    };
  }
}
