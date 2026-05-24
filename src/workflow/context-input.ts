// Expand @file mentions and !command prefixes into prompt context blocks.

import { readFile } from "node:fs/promises";
import { isAbsolute, normalize, resolve } from "node:path";
import { spawn } from "node:child_process";
import { parseFileMentions, parseMentionToken } from "./file-mention-parser.js";

const MAX_FILE_CHARS = 80_000;
const TOKEN_WARN_CHARS = 40_000; // ~10k tokens heuristic

function safeResolve(cwd: string, inputPath: string): string {
  const abs = isAbsolute(inputPath) ? normalize(inputPath) : resolve(cwd, inputPath);
  const root = normalize(cwd + "/");
  if (!(abs + "/").startsWith(root) && abs !== normalize(cwd)) {
    throw new Error(`Path escapes cwd: ${inputPath}`);
  }
  return abs;
}

async function loadFileSlice(
  cwd: string,
  mention: string,
  lineRange?: { start: number; end?: number },
): Promise<{ block: string; chars: number }> {
  const parsed = lineRange
    ? { path: mention, startLine: lineRange.start, endLine: lineRange.end ?? lineRange.start }
    : parseMentionToken(mention);
  const { path, startLine, endLine } = parsed;
  const abs = safeResolve(cwd, path);
  const content = await readFile(abs, "utf-8");
  let text = content;
  let label = path;

  if (startLine !== undefined) {
    const lines = content.split("\n");
    const start = Math.max(1, startLine) - 1;
    const end = Math.min(lines.length, endLine ?? startLine);
    text = lines.slice(start, end).join("\n");
    label = `${path}:${startLine}${endLine && endLine !== startLine ? `-${endLine}` : ""}`;
  }

  if (text.length > MAX_FILE_CHARS) {
    text = `${text.slice(0, MAX_FILE_CHARS)}\n...[truncated at ${MAX_FILE_CHARS} chars]`;
  }

  const block = [
    `<file path="${label}">`,
    "```",
    text,
    "```",
    "</file>",
  ].join("\n");

  return { block, chars: text.length };
}

async function runInlineCommand(cwd: string, command: string): Promise<string> {
  const result = await new Promise<{ stdout: string; stderr: string; code: number | null }>(
    (resolveP, reject) => {
      const child = spawn("bash", ["-lc", command], {
        cwd,
        env: process.env,
        stdio: ["ignore", "pipe", "pipe"],
      });
      let stdout = "";
      let stderr = "";
      child.stdout.on("data", (d) => { stdout += String(d); });
      child.stderr.on("data", (d) => { stderr += String(d); });
      child.on("error", reject);
      child.on("close", (code) => resolveP({ stdout, stderr, code }));
    },
  );

  const combined = [
    result.stdout ? `stdout:\n${result.stdout}` : "",
    result.stderr ? `stderr:\n${result.stderr}` : "",
    `exit=${String(result.code)}`,
  ]
    .filter(Boolean)
    .join("\n");

  return combined.slice(0, MAX_FILE_CHARS);
}

/** Expand `!cmd` prefix and `@path` mentions in user text before sending to the agent. */
export async function expandContextInput(cwd: string, text: string): Promise<string> {
  const trimmed = text.trim();
  if (!trimmed) return text;

  if (trimmed.startsWith("!")) {
    const command = trimmed.slice(1).trim();
    if (!command) return text;
    const output = await runInlineCommand(cwd, command);
    return [
      `User ran inline command: \`${command}\``,
      "<command_output>",
      output,
      "</command_output>",
      "Continue based on the command output above.",
    ].join("\n");
  }

  const mentions = parseFileMentions(trimmed);
  if (mentions.length === 0) return text;

  const blocks: string[] = [];
  let totalChars = 0;
  const seen = new Set<string>();

  for (const mention of mentions) {
    const key = mention.rawText;
    if (seen.has(key)) continue;
    seen.add(key);
    try {
      const { block, chars } = await loadFileSlice(cwd, mention.filePath, mention.lineRange);
      blocks.push(block);
      totalChars += chars;
    } catch (err) {
      blocks.push(`<file path="${mention.filePath}" error="${String(err)}" />`);
    }
  }

  let header = trimmed;
  if (totalChars >= TOKEN_WARN_CHARS) {
    header = `[Warning: attached files ~${Math.round(totalChars / 4)} tokens]\n${trimmed}`;
  }

  return [header, "", "Attached context:", ...blocks].join("\n");
}
