// Unified Jac CLI helpers — delegates to lib/jac/jac via Python toolchain bridge.

import type { JacDiagnostic } from "./jac-types.js";
import {
  bridgeFindJacBinary,
  findJacBinaryOnPath,
  bridgeParseJacCheckOutput,
  bridgeRunJacCheck,
  bridgeRunJacCommand,
  bridgeRunJacFormat,
  bridgeRunJacRun,
  bridgeRunJacTest,
  type JacCommandResult,
} from "./jac-bridge.js";

export type { JacDiagnostic } from "./jac-types.js";
export { fingerprintErrors, formatDiagnostics } from "./jac-types.js";
export type { JacCommandResult };

/** @deprecated Use bridge implementation; kept for tests and sync call sites. */
export async function parseJacCheckOutput(stdout: string, stderr: string): Promise<JacDiagnostic[]> {
  return bridgeParseJacCheckOutput(stdout, stderr);
}

/** Async lookup via lib/jac/jac toolchain bridge. */
export async function findJacBinary(): Promise<string | null> {
  return bridgeFindJacBinary();
}

/** Sync PATH probe — use when async bridge is unavailable (e.g. LSP config). */
export function findJacBinarySync(): string | null {
  return findJacBinaryOnPath();
}

export async function runJacCommand(
  cmd: string[],
  cwd: string,
  options?: { timeoutMs?: number; parseDiagnostics?: boolean },
): Promise<JacCommandResult> {
  return bridgeRunJacCommand(cmd, cwd, options);
}

export async function runJacCheck(
  cwd: string,
  files?: string[],
): Promise<{
  diagnostics: JacDiagnostic[];
  rawOutput: string;
  exitCode: number;
  exitError?: string;
}> {
  return bridgeRunJacCheck(cwd, files);
}

export async function runJacFormat(
  cwd: string,
  files: string[],
): Promise<{ changed: boolean; rawOutput: string; exitCode: number }> {
  return bridgeRunJacFormat(cwd, files);
}

export async function runJacTest(
  cwd: string,
  files?: string[],
): Promise<{
  passed: boolean;
  rawOutput: string;
  exitCode: number;
  diagnostics: JacDiagnostic[];
}> {
  return bridgeRunJacTest(cwd, files);
}

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
  return bridgeRunJacRun(cwd, file, options);
}
