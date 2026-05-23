// ────────────────────────────────────────────────────────────────────────────
// Local jac check helpers — used by slash commands and the autocheck hook for
// immediate, host-side feedback without depending on the MCP round-trip.
// ────────────────────────────────────────────────────────────────────────────

import type { JacDiagnostic } from "./types.js";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { accessSync, constants } from "node:fs";
import { join, delimiter } from "node:path";

const execFileAsync = promisify(execFile);

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
  // Windows: .cmd / .exe wrappers; POSIX: bare names
  const isWin = process.platform === "win32";
  const extensions = isWin ? ["", ".cmd", ".exe"] : [""];
  const pathDirs = (process.env.PATH || "").split(delimiter).filter(Boolean);
  for (const cmd of candidates) {
    for (const dir of pathDirs) {
      for (const ext of extensions) {
        try {
          accessSync(join(dir, `${cmd}${ext}`), constants.X_OK);
          return cmd;
        } catch {}
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

/** Run `jac format` in-place on the given files. Returns true if any file was changed. */
export async function runJacFormat(
  jacBin: string,
  cwd: string,
  files: string[],
): Promise<{ changed: boolean; rawOutput: string }> {
  const args = ["format", ...files];
  try {
    const { stdout, stderr } = await execFileAsync(jacBin, args, { cwd });
    const combined = (stdout + stderr).trim();
    // jac format exits 0 when no changes needed, non-zero when changes were made
    return { changed: combined.includes("changed"), rawOutput: combined };
  } catch (err: any) {
    const stdout = err.stdout || "";
    const stderr = err.stderr || "";
    const combined = (stdout + stderr).trim();
    // Exit 1 can mean "formatted and changed files" (success) or actual parse errors
    const changed = combined.includes("changed") && !combined.includes("FAILURES");
    return { changed, rawOutput: combined };
  }
}

/** Run `jac check` and return parsed diagnostics plus raw output. */
export async function runJacCheck(
  jacBin: string,
  cwd: string,
  files?: string[],
): Promise<{
  diagnostics: JacDiagnostic[];
  rawOutput: string;
  exitError?: string;
}> {
  const args = ["check"];
  if (files && files.length > 0) args.push(...files);
  try {
    const { stdout, stderr } = await execFileAsync(jacBin, args, { cwd });
    return { diagnostics: parseJacCheckOutput(stdout, stderr), rawOutput: stdout + stderr };
  } catch (err: any) {
    const stdout = err.stdout || "";
    const stderr = err.stderr || "";
    const diagnostics = parseJacCheckOutput(stdout, stderr);
    return {
      diagnostics,
      rawOutput: stdout + stderr,
      exitError: diagnostics.length === 0 ? (stderr || err.message || "Unknown error") : undefined,
    };
  }
}
