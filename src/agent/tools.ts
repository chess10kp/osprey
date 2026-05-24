import { readFile, writeFile, mkdir } from "node:fs/promises";
import { existsSync } from "node:fs";
import { dirname, isAbsolute, normalize, resolve } from "node:path";
import { spawn } from "node:child_process";
import { Type } from "typebox";
import type { AgentTool } from "@earendil-works/pi-agent-core";
import { loadProjectConfig } from "../config/project-config.js";
import {
  formatDiagnostics,
  runJacCheck,
  runJacFormat,
  runJacTest,
  runJacRun,
  runJacCommand,
} from "../jac/jac-cli.js";
import { runJacDoctor } from "../jac/jac-doctor.js";
import type { JacDiagnostic } from "../jac/jac-types.js";
import { createTaskTools } from "./task-tools.js";
import { renderMermaidAscii } from "../render/mermaid-render.js";
import {
  getFileDiagnostics,
  getMultiFileDiagnostics,
  getHoverInfo,
  findDefinitions,
  findReferences,
  formatLspDiagnostics,
  formatHoverInfo,
  formatLocations,
} from "../jac/lsp-tools.js";
import { truncateToolOutput, wrapToolsOutputLimit } from "./tool-output-limit.js";

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
  try {
    const { diagnostics, rawOutput, exitCode } = await runJacCheck(cwd, [path]);
    const errors = diagnostics.filter((d) => d.severity === "error");
    const warnings = diagnostics.filter((d) => d.severity === "warning");
    if (errors.length === 0 && warnings.length === 0 && exitCode === 0) {
      return `[autocheck] jac check passed for ${path}`;
    }
    const parts = [
      `[autocheck] jac check: ${errors.length} error(s), ${warnings.length} warning(s)`,
      diagnostics.length > 0 ? formatDiagnostics(diagnostics) : "",
      rawOutput.trim() ? `raw:\n${truncateToolOutput(rawOutput)}` : "",
    ].filter(Boolean);
    return parts.join("\n");
  } catch (error) {
    return `[autocheck] jac check failed: ${String(error)}`;
  }
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
        content: [{ type: "text", text: truncateToolOutput(content) }],
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
          stdout: truncateToolOutput(result.stdout),
          stderr: truncateToolOutput(result.stderr),
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
      const result = await runJacCommand(params.args, cwd, {
        timeoutMs: (params.timeout ?? 120) * 1000,
        parseDiagnostics: params.args[0] === "check",
      });
      const text = [
        `command: jac ${params.args.join(" ")}`,
        `exit=${String(result.exitCode)}`,
        result.diagnostics.length > 0 ? formatDiagnostics(result.diagnostics) : "",
        result.stdout ? `stdout:\n${truncateToolOutput(result.stdout)}` : "",
        result.stderr ? `stderr:\n${truncateToolOutput(result.stderr)}` : "",
      ].filter(Boolean).join("\n\n");
      return { content: [{ type: "text", text }], details: { ...result, command: `jac ${params.args.join(" ")}` } };
    },
  };

  const jacCheckTool: AgentTool = {
    name: "jac_check",
    label: "Jac Check",
    description: "Run jac check and return structured diagnostics.",
    parameters: Type.Object({
      files: Type.Optional(Type.Array(Type.String({ description: "Optional .jac file paths" }))),
    }),
    execute: async (_toolCallId, rawParams) => {
      const params = rawParams as { files?: string[] };
      const { diagnostics, rawOutput, exitCode, exitError } = await runJacCheck(cwd, params.files);
      if (exitError) {
        throw new Error(exitError);
      }
      const errors = diagnostics.filter((d) => d.severity === "error");
      const warnings = diagnostics.filter((d) => d.severity === "warning");
      const text = [
        exitCode === 0 && errors.length === 0
          ? "jac check passed — no errors."
          : `jac check: ${errors.length} error(s), ${warnings.length} warning(s)`,
        diagnostics.length > 0 ? formatDiagnostics(diagnostics) : "",
        rawOutput.trim() ? `\n--- raw output ---\n${truncateToolOutput(rawOutput)}` : "",
      ].filter(Boolean).join("\n\n");
      return {
        content: [{ type: "text", text }],
        details: { exitCode, diagnostics, rawOutput },
      };
    },
  };

  const jacDoctorTool: AgentTool = {
    name: "jac_doctor",
    label: "Jac Doctor",
    description: "Check jac CLI, project files, jac.toml, and MCP availability.",
    parameters: Type.Object({}),
    execute: async () => {
      const report = await runJacDoctor(cwd);
      return {
        content: [{ type: "text", text: report.summary }],
        details: report,
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
        result.stdout ? `stdout:\n${truncateToolOutput(result.stdout)}` : "",
        result.stderr ? `stderr:\n${truncateToolOutput(result.stderr)}` : "",
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
        result.stdout ? `stdout:\n${truncateToolOutput(result.stdout)}` : "",
        result.stderr ? `stderr:\n${truncateToolOutput(result.stderr)}` : "",
      ].filter(Boolean).join("\n\n");
      return { content: [{ type: "text", text }], details: { ...result, command: pieces.join(" ") } };
    },
  };

  const jacFixTool: AgentTool = {
    name: "jac_fix",
    label: "Jac Fix",
    description: "Run a capped jac check/format/check loop and report diagnostics.",
    parameters: Type.Object({
      maxAttempts: Type.Optional(Type.Number({ minimum: 1, maximum: 10 })),
      files: Type.Optional(Type.Array(Type.String({ description: "Optional .jac file paths" }))),
    }),
    execute: async (_toolCallId, rawParams) => {
      const params = rawParams as { maxAttempts?: number; files?: string[] };
      const cfg = loadProjectConfig(cwd);
      const maxAttempts = params.maxAttempts ?? cfg.maxFixAttempts ?? 3;
      const attempts: Array<{
        attempt: number;
        exitCode: number;
        errorCount: number;
        formatted?: boolean;
        diagnostics: JacDiagnostic[];
      }> = [];
      let lastFingerprint: string | undefined;

      for (let i = 1; i <= maxAttempts; i++) {
        const check = await runJacCheck(cwd, params.files);
        const errors = check.diagnostics.filter((d) => d.severity === "error");
        attempts.push({
          attempt: i,
          exitCode: check.exitCode,
          errorCount: errors.length,
          diagnostics: check.diagnostics,
        });

        if (errors.length === 0) break;

        const fp = errors.map((d) => `${d.file}:${d.line}:${d.message}`).sort().join("\n");
        if (lastFingerprint && lastFingerprint === fp) break;
        lastFingerprint = fp;

        const formatTargets = [...new Set(errors.map((d) => d.file).filter(Boolean))];
        if (formatTargets.length > 0) {
          const formatted = await runJacFormat(cwd, formatTargets);
          attempts[attempts.length - 1].formatted = formatted.changed;
        }
      }

      const last = attempts[attempts.length - 1];
      const ok = Boolean(last && last.errorCount === 0);
      const lastErrors = last?.diagnostics.filter((d) => d.severity === "error") ?? [];
      const summary = attempts
        .map((a) => `attempt ${a.attempt}: errors=${a.errorCount}${a.formatted !== undefined ? ` formatChanged=${String(a.formatted)}` : ""}`)
        .join("\n");
      const verbose = Boolean(cfg.verbose);
      const text = [
        ok ? "jac_fix: success" : "jac_fix: unresolved after max attempts",
        summary,
        lastErrors.length > 0 ? `\n${formatDiagnostics(lastErrors)}` : "",
      ].filter(Boolean).join("\n");

      const verboseText = verbose
        ? "\n\n" + attempts.map((a) => [
          `--- attempt ${a.attempt} ---`,
          a.diagnostics.length > 0 ? formatDiagnostics(a.diagnostics) : "(no diagnostics)",
        ].join("\n")).join("\n")
        : "";

      return {
        content: [{ type: "text", text: text + verboseText }],
        details: { ok, maxAttempts, attempts, verbose },
      };
    },
  };

  const jacTestTool: AgentTool = {
    name: "jac_test",
    label: "Jac Test",
    description: "Run jac test and return parsed diagnostics.",
    parameters: Type.Object({
      files: Type.Optional(Type.Array(Type.String({ description: "Optional test file paths" }))),
    }),
    execute: async (_toolCallId, rawParams) => {
      const params = rawParams as { files?: string[] };
      const result = await runJacTest(cwd, params.files);
      const errors = result.diagnostics.filter((d) => d.severity === "error");
      const text = [
        result.passed ? "jac test: passed" : `jac test: failed (${errors.length} error(s))`,
        result.diagnostics.length > 0 ? formatDiagnostics(result.diagnostics) : "",
        result.rawOutput.trim() ? `\n--- raw output ---\n${truncateToolOutput(result.rawOutput)}` : "",
      ].filter(Boolean).join("\n\n");
      return {
        content: [{ type: "text", text }],
        details: result,
      };
    },
  };

  const jacFormatTool: AgentTool = {
    name: "jac_format",
    label: "Jac Format",
    description: "Run jac format on one or more files.",
    parameters: Type.Object({
      files: Type.Array(Type.String({ description: ".jac file paths" })),
    }),
    execute: async (_toolCallId, rawParams) => {
      const params = rawParams as { files: string[] };
      const result = await runJacFormat(cwd, params.files);
      const text = [
        result.changed ? `formatted: ${params.files.join(", ")}` : "no formatting changes",
        result.rawOutput.trim() ? truncateToolOutput(result.rawOutput) : "",
      ].filter(Boolean).join("\n\n");
      return {
        content: [{ type: "text", text }],
        details: result,
      };
    },
  };

  const jacRunTool: AgentTool = {
    name: "jac_run",
    label: "Jac Run",
    description: "Run a Jac file and return stdout/stderr. Use for runtime verification.",
    parameters: Type.Object({
      file: Type.String({ description: "Path to .jac file to run" }),
      args: Type.Optional(Type.Array(Type.String({ description: "Additional arguments" }))),
      timeout: Type.Optional(Type.Number({ minimum: 1, maximum: 300 })),
    }),
    execute: async (_toolCallId, rawParams) => {
      const params = rawParams as { file: string; args?: string[]; timeout?: number };
      const result = await runJacRun(cwd, params.file, {
        args: params.args,
        timeoutMs: (params.timeout ?? 60) * 1000,
      });
      const parts = [
        `command: jac run ${params.file}`,
        `exit=${String(result.exitCode)}`,
        result.stdout ? `stdout:\n${truncateToolOutput(result.stdout)}` : "",
        result.stderr ? `stderr:\n${truncateToolOutput(result.stderr)}` : "",
        result.error ? `error: ${result.error}` : "",
      ].filter(Boolean);
      return {
        content: [{ type: "text", text: parts.join("\n\n") }],
        details: result,
      };
    },
  };

  const globTool: AgentTool = {
    name: "glob",
    label: "Find Files",
    description: "Find files by glob pattern. Returns matching paths relative to cwd.",
    parameters: Type.Object({
      pattern: Type.String({ description: "Glob pattern (e.g. **\/*.jac, src\/**\/*.py)" }),
      maxResults: Type.Optional(Type.Number({ description: "Maximum results (default 50)" })),
    }),
    execute: async (_toolCallId, rawParams) => {
      const params = rawParams as { pattern: string; maxResults?: number };
      const { execSync } = await import("node:child_process");
      const cap = Math.min(params.maxResults ?? 50, 200);
      try {
        const output = execSync(
          `find . -path ./node_modules -prune -o -path ./.git -prune -o -path ./.venv -prune -o -path ./dist -prune -o -name '${params.pattern.replace(/'/g, "'\\''")}' -print`,
          { cwd, encoding: "utf-8", maxBuffer: 1024 * 1024, timeout: 5000 },
        ).trim();
        const files = output
          .split("\n")
          .filter(Boolean)
          .map((f) => f.replace(/^\.\//, ""))
          .slice(0, cap);
        const text = files.length > 0
          ? `Found ${files.length} file(s):\n${files.join("\n")}`
          : `No files matching '${params.pattern}'`;
        return {
          content: [{ type: "text", text }],
          details: { pattern: params.pattern, count: files.length, files },
        };
      } catch (error) {
        return {
          content: [{ type: "text", text: `No files matching '${params.pattern}'` }],
          details: { pattern: params.pattern, count: 0, files: [] },
        };
      }
    },
  };

  const lspDiagTool: AgentTool = {
    name: "diagnostics",
    label: "Get Diagnostics",
    description: "Get compiler diagnostics for one or more files. Returns errors, warnings, and info.",
    parameters: Type.Object({
      files: Type.Array(Type.String({ description: "File paths to check" })),
    }),
    execute: async (_toolCallId, rawParams) => {
      const params = rawParams as { files: string[] };
      if (params.files.length === 0) throw new Error("At least one file is required");
      if (params.files.length === 1) {
        const diags = await getFileDiagnostics(cwd, params.files[0]!);
        return {
          content: [{ type: "text", text: formatLspDiagnostics(diags) }],
          details: { file: params.files[0], diagnostics: diags },
        };
      }
      const multiDiags = await getMultiFileDiagnostics(cwd, params.files);
      const parts: string[] = [];
      for (const [file, diags] of multiDiags) {
        if (diags.length > 0) {
          parts.push(`--- ${file} ---`);
          parts.push(formatLspDiagnostics(diags));
        }
      }
      const text = parts.length > 0 ? parts.join("\n\n") : "No diagnostics in any file.";
      return {
        content: [{ type: "text", text }],
        details: { allDiagnostics: Object.fromEntries(multiDiags) },
      };
    },
  };

  const lspHoverTool: AgentTool = {
    name: "hover",
    label: "Get Type Info",
    description: "Get type information and context at a specific position in a file.",
    parameters: Type.Object({
      file: Type.String({ description: "File path" }),
      line: Type.Number({ description: "Line number (1-based)" }),
      character: Type.Number({ description: "Character position (0-based)" }),
    }),
    execute: async (_toolCallId, rawParams) => {
      const params = rawParams as { file: string; line: number; character: number };
      const info = await getHoverInfo(cwd, params.file, params.line, params.character);
      return {
        content: [{ type: "text", text: formatHoverInfo(info) }],
        details: info,
      };
    },
  };

  const lspDefTool: AgentTool = {
    name: "definition",
    label: "Go to Definition",
    description: "Find the definition of a symbol at a position in a file.",
    parameters: Type.Object({
      file: Type.String({ description: "File path" }),
      line: Type.Number({ description: "Line number (1-based)" }),
      character: Type.Number({ description: "Character position (0-based)" }),
    }),
    execute: async (_toolCallId, rawParams) => {
      const params = rawParams as { file: string; line: number; character: number };
      const defs = await findDefinitions(cwd, params.file, params.line, params.character);
      return {
        content: [{ type: "text", text: formatLocations(defs, "Definitions") }],
        details: { definitions: defs },
      };
    },
  };

  const lspRefsTool: AgentTool = {
    name: "references",
    label: "Find References",
    description: "Find all references to the symbol at a position in a file.",
    parameters: Type.Object({
      file: Type.String({ description: "File path" }),
      line: Type.Number({ description: "Line number (1-based)" }),
      character: Type.Number({ description: "Character position (0-based)" }),
    }),
    execute: async (_toolCallId, rawParams) => {
      const params = rawParams as { file: string; line: number; character: number };
      const refs = await findReferences(cwd, params.file, params.line, params.character);
      return {
        content: [{ type: "text", text: formatLocations(refs, "References") }],
        details: { references: refs },
      };
    },
  };

  const mermaidTool: AgentTool = {
    name: "mermaid",
    label: "Render Mermaid",
    description: "Render a Mermaid diagram as ASCII art. Supports flowchart, sequence, class, ER, state diagrams.",
    parameters: Type.Object({
      source: Type.String({ description: "Mermaid diagram source code" }),
    }),
    execute: async (_toolCallId, rawParams) => {
      const params = rawParams as { source: string };
      const ascii = renderMermaidAscii(params.source);
      return {
        content: [{ type: "text", text: `\`\`\`\n${ascii}\n\`\`\`` }],
        details: { source: params.source, rendered: true },
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

  return wrapToolsOutputLimit([
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
    jacTestTool,
    jacFormatTool,
    jacRunTool,
    globTool,
    lspDiagTool,
    lspHoverTool,
    lspDefTool,
    lspRefsTool,
    mermaidTool,
    compactTool,
    ...createTaskTools(cwd),
  ]);
}
