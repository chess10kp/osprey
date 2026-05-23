import { readFile, writeFile, mkdir } from "node:fs/promises";
import { existsSync } from "node:fs";
import { dirname, isAbsolute, normalize, resolve } from "node:path";
import { spawn } from "node:child_process";
import { Type } from "typebox";
import type { AgentTool } from "@earendil-works/pi-agent-core";
import { loadProjectConfig } from "./project-config.js";

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

async function runBash(cwd: string, command: string, timeoutSeconds = 60): Promise<{ stdout: string; stderr: string; code: number | null; durationMs: number }> {
  const timeoutMs = timeoutSeconds * 1000;
  const startedAt = Date.now();

  const result = await new Promise<{ stdout: string; stderr: string; code: number | null }>((resolveP, reject) => {
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

    const timer = setTimeout(() => {
      child.kill("SIGTERM");
    }, timeoutMs);

    child.on("close", (code) => {
      clearTimeout(timer);
      resolveP({ stdout, stderr, code });
    });
  });

  return { ...result, durationMs: Date.now() - startedAt };
}

async function maybeAutoCheck(cwd: string, path: string): Promise<string | null> {
  const cfg = loadProjectConfig(cwd);
  if (!cfg.autocheck || !path.endsWith(".jac")) return null;
  const out = await runBash(cwd, "jac check", 120);
  return [
    "[autocheck] jac check",
    `exit=${String(out.code)}`,
    out.stdout ? `stdout:\n${limitText(out.stdout)}` : "",
    out.stderr ? `stderr:\n${limitText(out.stderr)}` : "",
  ].filter(Boolean).join("\n");
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
      const autocheck = await maybeAutoCheck(cwd, params.path);
      return {
        content: [{ type: "text", text: autocheck ? `Wrote ${params.path}\n\n${autocheck}` : `Wrote ${params.path}` }],
        details: { path: params.path, bytes: params.content.length, autocheck },
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
      const autocheck = await maybeAutoCheck(cwd, params.path);
      return {
        content: [{ type: "text", text: autocheck ? `Edited ${params.path}\n\n${autocheck}` : `Edited ${params.path}` }],
        details: { path: params.path, edits: params.edits.length, autocheck },
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
      const result = await runBash(cwd, params.command, params.timeout ?? 60);
      const payload = JSON.stringify(
        {
          code: result.code,
          stdout: limitText(result.stdout),
          stderr: limitText(result.stderr),
          durationMs: result.durationMs,
        },
        null,
        2,
      );

      return {
        content: [{ type: "text", text: payload }],
        details: result,
      };
    },
  };

  const jacCliTool: AgentTool = {
    name: "jac_cli",
    label: "Jac CLI",
    description: "Run a jac CLI command with arguments.",
    parameters: Type.Object({
      args: Type.Array(Type.String({ description: "CLI args after 'jac'" })),
      timeout: Type.Optional(Type.Number({ minimum: 1, maximum: 600 })),
    }),
    execute: async (_toolCallId, rawParams) => {
      const params = rawParams as { args: string[]; timeout?: number };
      if (!params.args?.length) {
        throw new Error("jac_cli requires at least one arg");
      }
      const command = ["jac", ...params.args].map((x) => JSON.stringify(x)).join(" ");
      const result = await runBash(cwd, command, params.timeout ?? 120);
      const text = [
        `command: jac ${params.args.join(" ")}`,
        `exit=${String(result.code)}`,
        result.stdout ? `stdout:\n${limitText(result.stdout)}` : "",
        result.stderr ? `stderr:\n${limitText(result.stderr)}` : "",
      ].filter(Boolean).join("\n\n");
      return { content: [{ type: "text", text }], details: { ...result, command: `jac ${params.args.join(" ")}` } };
    },
  };

  const jacCheckTool: AgentTool = {
    name: "jac_check",
    label: "Jac Check",
    description: "Run jac check and return diagnostics.",
    parameters: Type.Object({}),
    execute: async () => {
      const result = await runBash(cwd, "jac check", 120);
      const text = [
        `exit=${String(result.code)}`,
        result.stdout ? `stdout:\n${limitText(result.stdout)}` : "",
        result.stderr ? `stderr:\n${limitText(result.stderr)}` : "",
      ].filter(Boolean).join("\n\n");
      return { content: [{ type: "text", text }], details: result };
    },
  };

  const jacDoctorTool: AgentTool = {
    name: "jac_doctor",
    label: "Jac Doctor",
    description: "Check jac CLI, project files, and MCP availability.",
    parameters: Type.Object({}),
    execute: async () => {
      const cmd = [
        "set +e",
        "echo '== jac --version =='",
        "jac --version 2>&1",
        "echo ''",
        "echo '== jac files =='",
        "find . -name '*.jac' | head -n 20",
        "echo ''",
        "echo '== jac mcp == '",
        "jac mcp --help 2>&1 | head -n 20",
      ].join("\n");
      const result = await runBash(cwd, cmd, 120);
      return {
        content: [{ type: "text", text: `${limitText(result.stdout)}\n${limitText(result.stderr)}` }],
        details: result,
      };
    },
  };

  const jacListTemplatesTool: AgentTool = {
    name: "jac_list_templates",
    label: "Jac List Templates",
    description: "List jac create templates from CLI help output.",
    parameters: Type.Object({}),
    execute: async () => {
      const result = await runBash(cwd, "jac create --help", 60);
      const text = [
        `exit=${String(result.code)}`,
        result.stdout ? `stdout:\n${limitText(result.stdout)}` : "",
        result.stderr ? `stderr:\n${limitText(result.stderr)}` : "",
      ].filter(Boolean).join("\n\n");
      return { content: [{ type: "text", text }], details: result };
    },
  };

  const jacCreateTool: AgentTool = {
    name: "jac_create",
    label: "Jac Create",
    description: "Run jac create for a template/project name.",
    parameters: Type.Object({
      template: Type.String({ description: "Template name" }),
      name: Type.Optional(Type.String({ description: "Project/package name" })),
      args: Type.Optional(Type.Array(Type.String({ description: "Additional args" }))),
    }),
    execute: async (_toolCallId, rawParams) => {
      const params = rawParams as { template: string; name?: string; args?: string[] };
      const pieces = ["jac", "create", params.template];
      if (params.name) pieces.push(params.name);
      if (params.args?.length) pieces.push(...params.args);
      const command = pieces.map((x) => JSON.stringify(x)).join(" ");
      const result = await runBash(cwd, command, 120);
      const text = [
        `command: ${pieces.join(" ")}`,
        `exit=${String(result.code)}`,
        result.stdout ? `stdout:\n${limitText(result.stdout)}` : "",
        result.stderr ? `stderr:\n${limitText(result.stderr)}` : "",
      ].filter(Boolean).join("\n\n");
      return { content: [{ type: "text", text }], details: { ...result, command: pieces.join(" ") } };
    },
  };

  const jacFixTool: AgentTool = {
    name: "jac_fix",
    label: "Jac Fix",
    description: "Run a capped jac check/format/check loop and report results.",
    parameters: Type.Object({
      maxAttempts: Type.Optional(Type.Number({ minimum: 1, maximum: 10 })),
    }),
    execute: async (_toolCallId, rawParams) => {
      const params = rawParams as { maxAttempts?: number };
      const cfg = loadProjectConfig(cwd);
      const maxAttempts = params.maxAttempts ?? cfg.maxFixAttempts ?? 3;
      const attempts: Array<{ attempt: number; checkCode: number | null; formatCode?: number | null; checkStdout: string; checkStderr: string }> = [];

      for (let i = 1; i <= maxAttempts; i++) {
        const check = await runBash(cwd, "jac check", 120);
        attempts.push({
          attempt: i,
          checkCode: check.code,
          checkStdout: check.stdout,
          checkStderr: check.stderr,
        });
        if (check.code === 0) break;

        const format = await runBash(cwd, "jac format .", 120);
        attempts[attempts.length - 1].formatCode = format.code;
      }

      const ok = attempts.length > 0 && attempts[attempts.length - 1].checkCode === 0;
      const summary = attempts.map((a) => `attempt ${a.attempt}: check=${String(a.checkCode)}${a.formatCode !== undefined ? ` format=${String(a.formatCode)}` : ""}`).join("\n");
      const verbose = Boolean(cfg.verbose);
      const last = attempts[attempts.length - 1];
      const text = [
        ok ? "jac_fix: success" : "jac_fix: unresolved after max attempts",
        summary,
        last?.checkStdout ? `\nstdout:\n${limitText(last.checkStdout)}` : "",
        last?.checkStderr ? `\nstderr:\n${limitText(last.checkStderr)}` : "",
      ].filter(Boolean).join("\n");

      const verboseText = verbose
        ? "\n\n" + attempts.map((a) => [
          `--- attempt ${a.attempt} ---`,
          a.checkStdout ? `stdout:\n${limitText(a.checkStdout)}` : "",
          a.checkStderr ? `stderr:\n${limitText(a.checkStderr)}` : "",
        ].filter(Boolean).join("\n")).join("\n")
        : "";

      return {
        content: [{ type: "text", text: text + verboseText }],
        details: { ok, maxAttempts, attempts, verbose },
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

  return [
    readTool,
    writeTool,
    editTool,
    bashTool,
    jacCliTool,
    jacCheckTool,
    jacDoctorTool,
    jacListTemplatesTool,
    jacCreateTool,
    jacFixTool,
    compactTool,
  ];
}
