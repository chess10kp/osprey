// LSP bridge — language server integration for diagnostics, hover, definition, references.
//
// This provides LSP-like tools for the Jackal agent. When a language server
// is available (e.g. via pi LSP or jac LSP), the agent can query it directly.
// Falls back to jac check for diagnostics when no LSP is connected.

import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { existsSync, readFileSync } from "node:fs";
import { resolve, isAbsolute, relative } from "node:path";

const execFileAsync = promisify(execFile);

export interface LspDiagnostic {
  file: string;
  line: number;
  column?: number;
  severity: "error" | "warning" | "info" | "hint";
  message: string;
  code?: string | number;
  source?: string;
}

export interface LspHoverInfo {
  file: string;
  line: number;
  character: number;
  contents: string[];
  range?: { startLine: number; startChar: number; endLine: number; endChar: number };
}

export interface LspLocation {
  file: string;
  line: number;
  character?: number;
  endLine?: number;
  endCharacter?: number;
  text?: string;
}

/**
 * Get diagnostics for a file using jac check.
 * This is the primary fallback when no dedicated LSP is available.
 */
export async function getFileDiagnostics(
  cwd: string,
  filePath: string,
): Promise<LspDiagnostic[]> {
  const abs = isAbsolute(filePath) ? filePath : resolve(cwd, filePath);
  if (!existsSync(abs)) {
    return [{ file: filePath, line: 0, severity: "error", message: `File not found: ${filePath}` }];
  }

  const { findJacBinary } = await import("./jac-cli.js");
  const jacBin = findJacBinary();
  if (!jacBin) {
    return [{ file: filePath, line: 0, severity: "error", message: "jac binary not found" }];
  }

  try {
    const rel = relative(cwd, abs);
    const { stdout, stderr } = await execFileAsync(jacBin, ["check", rel], {
      cwd,
      timeout: 30_000,
    });

    return parseCheckOutput(stdout + "\n" + stderr, filePath);
  } catch (err: unknown) {
    const e = err as { stdout?: string; stderr?: string };
    const output = (e.stdout ?? "") + "\n" + (e.stderr ?? "");
    if (output.trim()) {
      return parseCheckOutput(output, filePath);
    }
    return [{ file: filePath, line: 0, severity: "error", message: String(err) }];
  }
}

/**
 * Get diagnostics for multiple files at once.
 */
export async function getMultiFileDiagnostics(
  cwd: string,
  filePaths: string[],
): Promise<Map<string, LspDiagnostic[]>> {
  const results = new Map<string, LspDiagnostic[]>();
  const uniqueFiles = [...new Set(filePaths)];

  // Run jac check once for all files
  const { findJacBinary } = await import("./jac-cli.js");
  const jacBin = findJacBinary();
  if (!jacBin) {
    for (const f of uniqueFiles) {
      results.set(f, [{ file: f, line: 0, severity: "error", message: "jac binary not found" }]);
    }
    return results;
  }

  try {
    const rels = uniqueFiles.map((f) => relative(cwd, isAbsolute(f) ? f : resolve(cwd, f)));
    const { stdout, stderr } = await execFileAsync(jacBin, ["check", ...rels], {
      cwd,
      timeout: 60_000,
    });

    const allDiags = parseCheckOutput(stdout + "\n" + stderr);

    for (const f of uniqueFiles) {
      const rel = relative(cwd, isAbsolute(f) ? f : resolve(cwd, f));
      const fileDiags = allDiags.filter(
        (d) => d.file === rel || d.file === f || d.file.endsWith(`/${rel}`),
      );
      results.set(f, fileDiags);
    }
  } catch (err: unknown) {
    const e = err as { stdout?: string; stderr?: string };
    const output = (e.stdout ?? "") + "\n" + (e.stderr ?? "");
    if (output.trim()) {
      const allDiags = parseCheckOutput(output);
      for (const f of uniqueFiles) {
        const rel = relative(cwd, isAbsolute(f) ? f : resolve(cwd, f));
        results.set(f, allDiags.filter((d) => d.file === rel || d.file === f));
      }
    }
  }

  return results;
}

/**
 * Get hover-like information at a position in a file.
 * Falls back to reading the file and extracting the line context.
 */
export async function getHoverInfo(
  cwd: string,
  filePath: string,
  line: number,
  character: number,
): Promise<LspHoverInfo> {
  const abs = isAbsolute(filePath) ? filePath : resolve(cwd, filePath);

  if (!existsSync(abs)) {
    return { file: filePath, line, character, contents: [`File not found: ${filePath}`] };
  }

  try {
    const content = readFileSync(abs, "utf-8");
    const lines = content.split("\n");
    const targetLine = lines[line - 1];

    // Extract context: the target line and surrounding lines
    const startLine = Math.max(0, line - 3);
    const endLine = Math.min(lines.length, line + 2);
    const contextLines = lines.slice(startLine, endLine).map((l, i) => {
      const lineNum = startLine + i + 1;
      const marker = lineNum === line ? " >" : "  ";
      return `${marker} ${String(lineNum).padStart(4)} | ${l}`;
    });

    // Try to extract the symbol at the character position
    const symbol = targetLine ? extractSymbol(targetLine, character) : "";

    const contents: string[] = [];
    if (symbol) {
      contents.push(`Symbol: ${symbol}`);
    }
    contents.push(`${filePath}:${line}:${character}`);
    contents.push("");
    contents.push(...contextLines);

    return { file: filePath, line, character, contents };
  } catch (error) {
    return {
      file: filePath,
      line,
      character,
      contents: [`Error reading file: ${error instanceof Error ? error.message : String(error)}`],
    };
  }
}

/**
 * Find definition-like references (grep-based fallback).
 * Looks for declarations matching the symbol.
 */
export async function findDefinitions(
  cwd: string,
  filePath: string,
  line: number,
  character: number,
): Promise<LspLocation[]> {
  const abs = isAbsolute(filePath) ? filePath : resolve(cwd, filePath);
  if (!existsSync(abs)) return [];

  try {
    const content = readFileSync(abs, "utf-8");
    const targetLine = content.split("\n")[line - 1];
    if (!targetLine) return [];

    const symbol = extractSymbol(targetLine, character);
    if (!symbol) return [];

    // Search for declaration patterns in the project
    return searchForDeclaration(cwd, symbol);
  } catch {
    return [];
  }
}

/**
 * Find references to a symbol across the project (grep-based fallback).
 */
export async function findReferences(
  cwd: string,
  filePath: string,
  line: number,
  character: number,
): Promise<LspLocation[]> {
  const abs = isAbsolute(filePath) ? filePath : resolve(cwd, filePath);
  if (!existsSync(abs)) return [];

  try {
    const content = readFileSync(abs, "utf-8");
    const targetLine = content.split("\n")[line - 1];
    if (!targetLine) return [];

    const symbol = extractSymbol(targetLine, character);
    if (!symbol) return [];

    return searchForReferences(cwd, symbol);
  } catch {
    return [];
  }
}

// ── Internal helpers ──────────────────────────────────────────────

function parseCheckOutput(
  output: string,
  defaultFile?: string,
): LspDiagnostic[] {
  const diagnostics: LspDiagnostic[] = [];
  const lines = output.split("\n");

  for (const raw of lines) {
    const stripped = raw.replace(/\x1b\[[0-9;]*m/g, "").trim();
    if (!stripped) continue;

    // Standard gcc-like format: file:line:col: severity: message
    const match = stripped.match(/^(.+?):(\d+):(\d+):\s+(error|warning|info):\s+(.*)$/i);
    if (match) {
      diagnostics.push({
        file: match[1]!,
        line: parseInt(match[2]!, 10),
        column: parseInt(match[3]!, 10),
        severity: match[4]!.toLowerCase() as LspDiagnostic["severity"],
        message: match[5]!,
      });
    }
  }

  if (diagnostics.length === 0 && defaultFile) {
    // Try to extract any error-like line
    const errorMatch = output.match(/error:\s*(.+)/i);
    if (errorMatch) {
      diagnostics.push({
        file: defaultFile,
        line: 0,
        severity: "error",
        message: errorMatch[1]!.trim(),
      });
    }
  }

  return diagnostics;
}

function extractSymbol(line: string, character: number): string {
  if (!line || character < 0 || character >= line.length) return "";

  // Find the boundaries of the word/identifier at the character position
  const isIdentChar = (ch: string) => /[\w.]/.test(ch);

  let start = character;
  while (start > 0 && isIdentChar(line[start - 1]!)) start--;

  let end = character;
  while (end < line.length && isIdentChar(line[end]!)) end++;

  if (start === end) return "";

  // Split on dots to get the last part (for qualified names)
  const full = line.slice(start, end);
  const parts = full.split(".");
  return parts[parts.length - 1] ?? full;
}

async function searchForDeclaration(cwd: string, symbol: string): Promise<LspLocation[]> {
  const results: LspLocation[] = [];
  try {
    const { stdout } = await execFileAsync(
      "grep",
      ["-rn", "-E", `^(can |test )?\\b${escapeRegex(symbol)}\\b`, "--include=*.jac", "--include=*.py", "."],
      { cwd, timeout: 10_000 },
    );

    for (const line of stdout.split("\n").filter(Boolean)) {
      const match = line.match(/^\.\/([^:]+):(\d+):(.*)$/);
      if (match) {
        results.push({
          file: match[1]!,
          line: parseInt(match[2]!, 10),
          text: match[3]!.trim(),
        });
      }
    }
  } catch {
    // grep returns non-zero when no matches
  }
  return results;
}

async function searchForReferences(cwd: string, symbol: string): Promise<LspLocation[]> {
  const results: LspLocation[] = [];
  try {
    const { stdout } = await execFileAsync(
      "grep",
      ["-rn", "-w", symbol, "--include=*.jac", "--include=*.py", "."],
      { cwd, timeout: 10_000 },
    );

    for (const line of stdout.split("\n").filter(Boolean)) {
      const match = line.match(/^\.\/([^:]+):(\d+):(.*)$/);
      if (match) {
        results.push({
          file: match[1]!,
          line: parseInt(match[2]!, 10),
          text: match[3]!.trim(),
        });
      }
    }
  } catch {
    // grep returns non-zero when no matches
  }
  return results;
}

function escapeRegex(str: string): string {
  return str.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/**
 * Format LSP diagnostics for display.
 */
export function formatLspDiagnostics(diagnostics: LspDiagnostic[]): string {
  if (diagnostics.length === 0) return "No diagnostics.";

  return diagnostics
    .map((d) => {
      const col = d.column ? `:${d.column}` : "";
      const code = d.code ? ` [${d.code}]` : "";
      const src = d.source ? ` (${d.source})` : "";
      return `${d.file}:${d.line}${col} [${d.severity}]${code}${src} ${d.message}`;
    })
    .join("\n");
}

/**
 * Format hover info for display.
 */
export function formatHoverInfo(info: LspHoverInfo): string {
  return info.contents.join("\n");
}

/**
 * Format references/definitions for display.
 */
export function formatLocations(locations: LspLocation[], label = "Results"): string {
  if (locations.length === 0) return `No ${label.toLowerCase()} found.`;

  return locations
    .slice(0, 20)
    .map((loc) => {
      const text = loc.text ? `: ${loc.text.length > 100 ? `${loc.text.slice(0, 97)}...` : loc.text}` : "";
      return `${loc.file}:${loc.line}${text}`;
    })
    .join("\n");
}
