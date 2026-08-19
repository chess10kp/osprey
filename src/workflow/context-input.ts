// Expand @file mentions and !command prefixes into prompt context blocks.

import { readFile } from "node:fs/promises";
import { normalize, resolve } from "node:path";
import { spawn } from "node:child_process";
import { parseFileMentions, parseMentionToken } from "./file-mention-parser.js";

const MAX_FILE_CHARS = 80_000;
const TOKEN_WARN_CHARS = 40_000;

function safeResolve(cwd: string, inputPath: string): string {
  const abs = normalize(resolve(cwd, inputPath));
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
    ? {
      path: mention,
      startLine: lineRange.start,
      endLine: lineRange.end ?? lineRange.start,
    }
    : parseMentionToken(mention);

  const filePath = parsed.path ?? mention;
  const startLine = parsed.startLine;
  const endLine = parsed.endLine;

  const absPath = safeResolve(cwd, filePath);
  const content = await readFile(absPath, "utf-8");

  let text = content;
  let label = filePath;

  if (typeof startLine === "number") {
    const lines = content.split("\n");
    const start = Math.max(1, startLine) - 1;
    const end = Math.min(lines.length, endLine ?? startLine);
    text = lines.slice(start, end).join("\n");
    const endSuffix = endLine && endLine !== startLine ? `-${endLine}` : "";
    label = `${filePath}:${startLine}${endSuffix}`;
  }

  if (text.length > MAX_FILE_CHARS) {
    text = text.slice(0, MAX_FILE_CHARS) + `\n...[truncated at ${MAX_FILE_CHARS} chars]`;
  }

  const block = `<file path="${label}\">\n\`\`\`\n${text}\n\`\`\`\n</file>`;
  return { block, chars: text.length };
}

async function runInlineCommand(cwd: string, command: string): Promise<string> {
  return new Promise((resolveOutput) => {
    const child = spawn("bash", ["-lc", command], {
      cwd,
      env: process.env,
      stdio: ["ignore", "pipe", "pipe"],
    });

    let stdout = "";
    let stderr = "";
    let resolved = false;
    let timer: ReturnType<typeof setTimeout> | null = null;

    const finish = (text: string) => {
      if (resolved) return;
      resolved = true;
      if (timer) clearTimeout(timer);
      resolveOutput(text.slice(0, MAX_FILE_CHARS));
    };

    child.stdout.on("data", (chunk) => {
      stdout += String(chunk);
    });
    child.stderr.on("data", (chunk) => {
      stderr += String(chunk);
    });

    child.on("error", (error) => {
      finish(`Command failed: ${String(error)}`);
    });

    child.on("close", (code) => {
      if (resolved) return;
      const parts: string[] = [];
      if (stdout) parts.push(`stdout:\n${stdout}`);
      if (stderr) parts.push(`stderr:\n${stderr}`);
      parts.push(`exit=${String(code)}`);
      finish(parts.join("\n"));
    });

    timer = setTimeout(() => {
      child.kill("SIGTERM");
      finish("Command timed out after 60 seconds");
    }, 60_000);
  });
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
  const seen = new Set<string>();
  let totalChars = 0;

  for (const mention of mentions) {
    if (seen.has(mention.rawText)) continue;
    seen.add(mention.rawText);

    try {
      const slice = await loadFileSlice(cwd, mention.filePath, mention.lineRange);
      blocks.push(slice.block);
      totalChars += slice.chars;
    } catch (error) {
      blocks.push(`<file path="${mention.filePath}" error="${String(error)}" />`);
    }
  }

  const header = totalChars >= TOKEN_WARN_CHARS
    ? `[Warning: attached files ~${Math.floor(totalChars / 4)} tokens]\n${trimmed}`
    : trimmed;

  return `${header}\n\nAttached context:\n${blocks.join("\n")}`;
}
