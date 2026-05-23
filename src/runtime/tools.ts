import { readFile, writeFile, mkdir } from "node:fs/promises";
import { existsSync } from "node:fs";
import { dirname, isAbsolute, normalize, resolve } from "node:path";
import { spawn } from "node:child_process";
import { Type } from "typebox";
import type { AgentTool } from "@earendil-works/pi-agent-core";

const MAX_TOOL_TEXT = 50_000;

function limitText(s: string): string {
  return s.length > MAX_TOOL_TEXT ? `${s.slice(0, MAX_TOOL_TEXT)}\n...[truncated]` : s;
}

function safeResolve(cwd: string, inputPath: string): string {
  const abs = isAbsolute(inputPath) ? normalize(inputPath) : resolve(cwd, inputPath);
  const root = normalize(cwd + "/");
  if (!(abs + "/").startsWith(root) && abs !== normalize(cwd)) {
    throw new Error(`Path escapes cwd: ${inputPath}`);
  }
  return abs;
}

export function createCoreTools(cwd: string): AgentTool[] {
  const readTool: AgentTool = {
    name: "read",
    label: "Read File",
    description: "Read a text file from the project.",
    parameters: Type.Object({
      path: Type.String({ description: "Path relative to cwd" }),
    }),
    execute: async (_toolCallId, rawParams) => {
      const params = rawParams as { path: string };
      const abs = safeResolve(cwd, params.path);
      const content = await readFile(abs, "utf-8");
      return {
        content: [{ type: "text", text: limitText(content) }],
        details: { path: params.path, bytes: content.length },
      };
    },
  };

  const writeTool: AgentTool = {
    name: "write",
    label: "Write File",
    description: "Create or overwrite a file.",
    parameters: Type.Object({
      path: Type.String({ description: "Path relative to cwd" }),
      content: Type.String({ description: "File content" }),
    }),
    execute: async (_toolCallId, rawParams) => {
      const params = rawParams as { path: string; content: string };
      const abs = safeResolve(cwd, params.path);
      await mkdir(dirname(abs), { recursive: true });
      await writeFile(abs, params.content, "utf-8");
      return {
        content: [{ type: "text", text: `Wrote ${params.path}` }],
        details: { path: params.path, bytes: params.content.length },
      };
    },
  };

  const editTool: AgentTool = {
    name: "edit",
    label: "Edit File",
    description: "Perform exact text replacements in a file.",
    parameters: Type.Object({
      path: Type.String(),
      edits: Type.Array(
        Type.Object({
          oldText: Type.String(),
          newText: Type.String(),
        }),
      ),
    }),
    execute: async (_toolCallId, rawParams) => {
      const params = rawParams as { path: string; edits: Array<{ oldText: string; newText: string }> };
      const abs = safeResolve(cwd, params.path);
      if (!existsSync(abs)) throw new Error(`File not found: ${params.path}`);
      const original = await readFile(abs, "utf-8");
      let updated = original;

      for (const [i, e] of params.edits.entries()) {
        const first = original.indexOf(e.oldText);
        if (first < 0) throw new Error(`Edit ${i}: oldText not found`);
        const second = original.indexOf(e.oldText, first + 1);
        if (second >= 0) throw new Error(`Edit ${i}: oldText is not unique`);
      }

      for (const e of params.edits) {
        updated = updated.replace(e.oldText, e.newText);
      }

      await writeFile(abs, updated, "utf-8");
      return {
        content: [{ type: "text", text: `Edited ${params.path}` }],
        details: { path: params.path, edits: params.edits.length },
      };
    },
  };

  const bashTool: AgentTool = {
    name: "bash",
    label: "Run Bash",
    description: "Run a shell command in project cwd.",
    parameters: Type.Object({
      command: Type.String(),
      timeout: Type.Optional(Type.Number({ minimum: 1, maximum: 600 })),
    }),
    execute: async (_toolCallId, rawParams) => {
      const params = rawParams as { command: string; timeout?: number };
      const timeoutMs = (params.timeout ?? 60) * 1000;
      const startedAt = Date.now();

      const result = await new Promise<{ stdout: string; stderr: string; code: number | null }>((resolveP, reject) => {
        const child = spawn("bash", ["-lc", params.command], {
          cwd,
          env: process.env,
          stdio: ["ignore", "pipe", "pipe"],
        });

        let stdout = "";
        let stderr = "";
        child.stdout.on("data", (d) => { stdout += String(d); });
        child.stderr.on("data", (d) => { stderr += String(d); });
        child.on("error", reject);

        const timer = setTimeout(() => {
          child.kill("SIGTERM");
        }, timeoutMs);

        child.on("close", (code) => {
          clearTimeout(timer);
          resolveP({ stdout, stderr, code });
        });
      });

      const payload = JSON.stringify(
        {
          code: result.code,
          stdout: limitText(result.stdout),
          stderr: limitText(result.stderr),
          durationMs: Date.now() - startedAt,
        },
        null,
        2,
      );

      return {
        content: [{ type: "text", text: payload }],
        details: {
          code: result.code,
          stdout: result.stdout,
          stderr: result.stderr,
          durationMs: Date.now() - startedAt,
        },
      };
    },
  };

  const compactTool: AgentTool = {
    name: "compact_context",
    label: "Compact Context",
    description: "Summarize older context to reduce token usage.",
    parameters: Type.Object({
      reason: Type.Optional(Type.String()),
    }),
    execute: async () => ({
      content: [{ type: "text", text: "Context compaction is not yet implemented in agent-next." }],
      details: { implemented: false },
      terminate: true,
    }),
  };

  return [readTool, writeTool, editTool, bashTool, compactTool];
}
