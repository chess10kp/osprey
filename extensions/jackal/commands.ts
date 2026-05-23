// ────────────────────────────────────────────────────────────────────────────
// Slash commands — all /command registrations for the Jackal extension.
//
// Each function takes the shared context ({ pi, ... }) and
// registers its commands via pi.registerCommand().
// ────────────────────────────────────────────────────────────────────────────

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

import { state, getVerboseOverride, setVerboseOverride } from "./types.js";
import { findJacBinary, formatDiagnostics, runJacCheck } from "./check.js";
import { toggleJacPlanMode, enableJacPlanMode } from "./plan-mode.js";
import {
  readJackalSettingsParsed,
  describeSubagentOverrides,
  setSubagentModelPin,
  clearSubagentModelPin,
  subagentModelCompletions,
  pickSubagentModelSpec,
} from "./settings.js";
import { getConfig, formatConfig } from "./config.js";
import { runNextAgentSmoke } from "../../agent-next/src/adapter.js";
import { writeFileSync, mkdirSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const execFileAsync = promisify(execFile);

export interface CommandContext {
  pi: ExtensionAPI;
  isVerbose: () => boolean;
}

// ──── /jac-doctor ────────────────────────────────────────────────────────

function registerJacDoctor({ pi, isVerbose }: CommandContext): void {
  pi.registerCommand("jac-doctor", {
    description:
      "Check Jac environment: binary, version, MCP availability, project structure.",
    handler: async (_args, ctx) => {
      const jacBin = findJacBinary();
      const lines: string[] = [];

      if (jacBin) {
        lines.push(`jac binary: ${jacBin}`);
        try {
          const { stdout } = await execFileAsync(jacBin, ["--version"]);
          lines.push(`jac version: ${stdout.trim()}`);
        } catch {}
        try {
          await execFileAsync(jacBin, ["mcp", "--inspect"]);
          lines.push("jac mcp: available (configured in jackal/mcp.json)");
        } catch {
          lines.push("jac mcp: NOT available — `jac mcp` failed. Update jaclang.");
        }
      } else {
        lines.push("jac: NOT FOUND (install with: pip install jaclang)");
      }

      lines.push(`verbose retries: ${isVerbose() ? "on" : "off"}`);
      lines.push(
        `auto-check on write/edit: ${pi.getFlag("jac-autocheck") ? "on" : "off"}`,
      );

      // Show .jackal project config
      const config = getConfig();
      lines.push("");
      lines.push(formatConfig(config));
      if (state.planMode) {
        const planMode = state.planMode;
        if (planMode.enabled)
          lines.push("jac plan mode: enabled (read-only)");
        else if (planMode.executing) {
          const completed = planMode.todos.filter((t) => t.completed).length;
          lines.push(
            `jac plan mode: executing (${completed}/${planMode.todos.length} steps completed)`,
          );
        }
      } else if (pi.getFlag("plan")) {
        lines.push("plan mode: start in plan mode (--plan)");
      } else {
        lines.push("plan mode: disabled");
      }
      if (state.workingFile)
        lines.push(`current working file: ${state.workingFile}`);

      const jacFiles: string[] = [];
      const { readdirSync, statSync } = await import("node:fs");
      const { join, extname } = await import("node:path");
      const walk = (dir: string): void => {
        try {
          for (const entry of readdirSync(dir)) {
            const full = join(dir, entry);
            if (
              entry.startsWith(".") ||
              entry === "node_modules" ||
              entry === ".jac" ||
              entry === "__pycache__"
            )
              continue;
            if (statSync(full).isDirectory()) {
              walk(full);
              continue;
            }
            if (extname(full) === ".jac") jacFiles.push(full.replace(ctx.cwd + "/", ""));
          }
        } catch {}
      };
      walk(ctx.cwd);

      if (jacFiles.length > 0) {
        lines.push(`\n.jac files found: ${jacFiles.length}`);
        lines.push(
          jacFiles
            .slice(0, 20)
            .map((f) => `  ${f}`)
            .join("\n"),
        );
        if (jacFiles.length > 20)
          lines.push(`  ... and ${jacFiles.length - 20} more`);
      } else {
        lines.push("\nNo .jac files found in project.");
      }

      ctx.ui.notify(lines.join("\n"), "info");
    },
  });
}

// ──── /jac-check ─────────────────────────────────────────────────────────

function registerJacCheck({ pi, isVerbose }: CommandContext): void {
  pi.registerCommand("jac-check", {
    description:
      "Run `jac check` on the project and display diagnostics in the TUI. When no file is provided, delegate to the LLM+MCP to pick target(s) and run lint_jac.",
    handler: async (args, ctx) => {
      const jacBin = findJacBinary();
      const target = args.trim();

      // Explicit file/target: run the host-side quick check
      if (target) {
        if (!jacBin) {
          ctx.ui.notify(
            "jac binary not found. Install with: pip install jaclang",
            "error",
          );
          return;
        }
        ctx.ui.setStatus("jac", "Checking...");
        try {
          const { diagnostics, rawOutput, exitError } = await runJacCheck(
            jacBin,
            ctx.cwd,
            [target],
          );
          if (exitError) {
            ctx.ui.notify(exitError, "error");
            return;
          }
          if (diagnostics.length === 0) {
            ctx.ui.notify("jac check passed — no errors or warnings.", "info");
          } else {
            const errors = diagnostics.filter((d) => d.severity === "error");
            const warnings = diagnostics.filter((d) => d.severity === "warning");
            let msg = `jac check: ${errors.length} error(s), ${warnings.length} warning(s)\n\n${formatDiagnostics(diagnostics)}`;
            if (isVerbose()) msg += "\n\n--- raw output ---\n" + rawOutput;
            ctx.ui.notify(msg, errors.length > 0 ? "error" : "warning");
          }
        } finally {
          ctx.ui.setStatus("jac", "");
        }
        return;
      }

      // No explicit target: delegate to LLM + MCP, or fall back to local check in plan mode
      if (state.planMode && state.planMode.enabled) {
        if (jacBin) {
          ctx.ui.notify(
            "Jac plan mode is enabled. Falling back to local `jac check` because lint_jac may be unavailable in plan mode.",
            "info",
          );
          ctx.ui.setStatus("jac", "Checking...");
          try {
            const { diagnostics, rawOutput, exitError } = await runJacCheck(
              jacBin,
              ctx.cwd,
              undefined,
            );
            if (exitError) {
              ctx.ui.notify(exitError, "error");
              return;
            }
            if (diagnostics.length === 0) {
              ctx.ui.notify("jac check passed — no errors or warnings.", "info");
            } else {
              const errors = diagnostics.filter((d) => d.severity === "error");
              const warnings = diagnostics.filter(
                (d) => d.severity === "warning",
              );
              let msg = `jac check: ${errors.length} error(s), ${warnings.length} warning(s)\n\n${formatDiagnostics(diagnostics)}`;
              if (isVerbose())
                msg += "\n\n--- raw output ---\n" + rawOutput;
              ctx.ui.notify(msg, errors.length > 0 ? "error" : "warning");
            }
          } finally {
            ctx.ui.setStatus("jac", "");
          }
          return;
        }

        ctx.ui.notify(
          "Jac plan mode is enabled and no local `jac` binary was found. To run linting you must either exit plan mode or install jac.",
          "warning",
        );
        return;
      }

      // Delegate to LLM: pick files and call MCP lint_jac / validate_jac
      const prompt = [
        "The user invoked `/jac-check` with no explicit file. Your job:",
        "1) Pick the single best .jac file (or minimal set) to run lint on using this priority:",
        "   • session working file (if set),",
        "   • jac.toml entry_point (if present),",
        "   • main.jac,",
        "   • most recently edited .jac files in the session,",
        "   • otherwise ask the user to pick a file.",
        "2) Call the Jac MCP tool `lint_jac` with the chosen file(s). If `lint_jac` is unavailable, call `validate_jac` instead.",
        "3) Summarise the result briefly as either:\n   PASS: no lint errors\n   or\n   FAIL: N issues\n   Then list up to 10 issues as bullets formatted: file:line:severity: message. For each issue provide a one-line suggested fix.",
        "4) Do NOT modify files. This is a read-only lint check.",
        "5) If you cannot decide on a file, ask the user a single clarifying question instead of guessing.",
        "Use available project context (workingFile) and do not run `jac run` or edits.",
      ].join("\n");

      pi.sendUserMessage(prompt);
    },
  });
}

// ──── /fix ───────────────────────────────────────────────────────────

function registerJacFix({ pi, isVerbose }: CommandContext): void {
  pi.registerCommand("fix", {
    description:
      "Run `jac check` and ask the agent to fix any reported errors via the Jac MCP (capped at 3 retries). Usage: /fix [file.jac] [description of the issue]",
    handler: async (args, ctx) => {
      const jacBin = findJacBinary();
      if (!jacBin) {
        ctx.ui.notify(
          "jac binary not found. Install with: pip install jaclang",
          "error",
        );
        return;
      }

      // Parse args to extract an optional .jac file target and a user description.
      // Heuristic: if the first token ends with .jac, treat it as the target;
      // everything else (or the whole string when no .jac token) is the prompt.
      const trimmed = args.trim();
      let target: string | undefined;
      let userPrompt: string | undefined;

      if (trimmed) {
        const firstToken = trimmed.split(/\s+/)[0]!;
        const rest = trimmed.slice(firstToken.length).trim();
        if (firstToken.endsWith(".jac")) {
          target = firstToken;
          userPrompt = rest || undefined;
        } else {
          userPrompt = trimmed;
        }
      }

      if (!target) target = state.workingFile;

      ctx.ui.setStatus("jac", "Checking...");
      const { diagnostics, rawOutput, exitError } = await runJacCheck(
        jacBin,
        ctx.cwd,
        target ? [target] : undefined,
      );
      ctx.ui.setStatus("jac", "");

      if (exitError) {
        ctx.ui.notify(`jac check failed:\n${exitError}`, "error");
        return;
      }

      const errors = diagnostics.filter((d) => d.severity === "error");
      const scope = target ? ` for \`${target}\`` : "";
      const verboseTail = isVerbose()
        ? `\n\n--- raw output ---\n${rawOutput}`
        : "";

      // When the user provided a description, run diagnosis-skill first.
      if (userPrompt) {
        const prompt = [
          `The user invoked \`/fix\`${scope} and described the issue:`,
          `> ${userPrompt}`,
          "",
          ...(errors.length > 0
            ? [
                `\`jac check\` reported ${errors.length} error(s):`,
                "",
                formatDiagnostics(errors),
                "",
              ]
            : [
                "`jac check` passed — no compiler errors were found.",
                "",
              ]),
          "Follow the **diagnosis-skill** workflow first:",
          "1. Gather evidence: read each affected file, call `explain_error` for unfamiliar codes, and inspect the AST with `get_ast` if an error line looks correct.",
          "2. Synthesize a diagnosis in the exact format shown in diagnosis-skill (Root cause, Affected files, Evidence, Proposed fix strategy, Risk).",
          "3. Validate your diagnosis: if uncertain, ask the user a single clarifying question instead of guessing.",
          "",
          "Once you have a confident diagnosis, proceed to the **fix-skill** workflow:",
          "4. Apply a focused edit based on your diagnosis (no unrelated refactors).",
          "5. Call `validate_jac` (or `check_syntax` for a faster parse-only pass) to verify.",
          "6. If new errors appear, repeat diagnosis → fix. Stop after at most 3 attempts on the same file.",
          "",
          "When all errors are resolved, give a brief summary of the diagnosis and the changes you made." +
            verboseTail,
        ].join("\n");

        pi.sendUserMessage(prompt);
        return;
      }

      // No user prompt — standard fix flow
      if (errors.length === 0) {
        ctx.ui.notify("jac check passed — nothing to fix.", "info");
        return;
      }

      const prompt = [
        `\`jac check\`${scope} reported ${errors.length} error(s):`,
        "",
        formatDiagnostics(errors),
        "",
        "Please fix these errors using the Jac MCP tools:",
        "1. For any unfamiliar error code, call `explain_error` with the code/message.",
        "2. Read each file at the reported line to understand the surrounding context.",
        "3. Apply a focused edit (no unrelated refactors).",
        "4. Call `validate_jac` (or `check_syntax` for a faster parse-only pass) to verify the fix.",
        "5. If new errors appear, repeat from step 1. Stop after at most 3 attempts on the same file.",
        "",
        "When all errors are resolved, give a brief summary of the changes you made." +
          verboseTail,
      ].join("\n");

      pi.sendUserMessage(prompt);
    },
  });
}

// ──── /jac-verbose ───────────────────────────────────────────────────────

function registerJacVerbose({ pi, isVerbose }: CommandContext): void {
  pi.registerCommand("jac-verbose", {
    description: "Toggle verbose Jac retries. Usage: /jac-verbose [on|off]",
    handler: async (args, ctx) => {
      const v = args.trim().toLowerCase();
      if (v === "on" || v === "true" || v === "1") {
        setVerboseOverride(true);
      } else if (v === "off" || v === "false" || v === "0") {
        setVerboseOverride(false);
      } else if (v === "") {
        setVerboseOverride(!isVerbose());
      } else {
        ctx.ui.notify("Usage: /jac-verbose [on|off]", "info");
        return;
      }
      ctx.ui.notify(`jac verbose: ${isVerbose() ? "on" : "off"}`, "info");
    },
  });
}

// ──── /osp ───────────────────────────────────────────────────────────

function registerJacOsp({ pi }: CommandContext): void {
  pi.registerCommand("osp", {
    description:
      "Generate Object-Spatial (walker/node/edge) Jac code. Usage: /osp <description>",
    handler: async (args, ctx) => {
      const desc = args.trim();
      if (!desc) {
        ctx.ui.notify(
          "Usage: /osp <description of the graph or walker you need>",
          "info",
        );
        return;
      }
      const prompt = [
        `The user wants Object-Spatial Programming (OSP) Jac code for: ${desc}`,
        "",
        "Follow the `osp-skill` workflow, leveraging the Jac MCP throughout:",
        "1. Call `list_examples` to see categories, then `get_example` for any walker/node/edge category that matches.",
        "   For deeper grounding, call `search_docs` with keywords like 'walker', 'spawn', 'visit', 'edge', 'by llm'.",
        "2. Identify nodes, edges, walkers, and where each ability lives (on the node vs on the walker).",
        "3. Write the file with all four building blocks and a `with entry { ... }` that spawns from `root`.",
        "4. Call `validate_jac` to verify it compiles. If it errors, follow `fix-skill` (max 3 attempts), using `explain_error` for unfamiliar codes.",
        "5. Briefly summarise the design choices (which node owns which ability, why typed edges if used).",
      ].join("\n");
      pi.sendUserMessage(prompt);
    },
  });
}

// ──── /refactor ──────────────────────────────────────────────────────────

function registerRefactor({ pi }: CommandContext): void {
  pi.registerCommand("refactor", {
    description:
      "Refactor Jac code safely. Usage: /refactor <short description> (or leave empty to open editor)",
    handler: async (args, ctx) => {
      let desc = args.trim();
      if (!desc) {
        const editorText = await ctx.ui.editor(
          "Describe the refactor you want (scope, symbols, files):",
          "",
        );
        if (!editorText) {
          ctx.ui.notify("Refactor cancelled.", "info");
          return;
        }
        desc = editorText.trim();
      }

      const prompt = [
        `The user requested a refactor: ${desc}`,
        "",
        "Follow the `refactor-skill` workflow adapted for Jac:",
        "1) Clarify scope if needed. Prefer session working file if relevant.",
        "2) Produce a short numbered Plan: of focused steps (2-6 steps).",
        "3) For each edit: inspect with `get_ast`/`read`, apply a minimal edit, then call `validate_jac` and `lint_jac` to verify.",
        "4) If errors appear, call `explain_error` and fix only targeted lines. Re-run validation.",
        "5) Smoke-test with `run_jac` or relevant walkers if available.",
        "6) Summarise changes and remaining concerns.",
        "",
        "Use Jac MCP tools (get_ast, validate_jac, lint_jac, explain_error, run_jac) for all analysis and verification. Do NOT modify unrelated code. If you cannot decide on scope or files, ask one clarifying question.",
      ].join("\n");

      pi.sendUserMessage(prompt);
    },
  });

  pi.registerCommand("refactor-skill", {
    description:
      "Run refactor flow seeded by Claude Directory skill. Usage: /refactor-skill <short description>",
    handler: async (args, ctx) => {
      const desc = args.trim();
      if (!desc) {
        ctx.ui.notify("Usage: /refactor-skill <short description>", "info");
        return;
      }

      const prompt = [
        `Use this external refactor skill as guidance: https://www.claudedirectory.org/skills/refactor`,
        `User request: ${desc}`,
        "",
        "Adapt the workflow to this Jac project: inspect code first, make minimal coherent edits, and verify with validate_jac/lint_jac after each change.",
      ].join("\n");

      pi.sendUserMessage(prompt);
    },
  });
}

// ──── /create ────────────────────────────────────────────────────────────

interface JacpackTemplate {
  name: string;
  description: string;
}

type CreateArgCompletion = {
  value: string;
  label: string;
  description?: string;
};

const JACPACK_CACHE_TTL_MS = 30_000;
let jacpackCache:
  | { jacBin: string; fetchedAt: number; templates: JacpackTemplate[] }
  | null = null;

type JacpackListResult = {
  templates: JacpackTemplate[];
  error?: string;
};

function parseJacpackTemplates(output: string): JacpackTemplate[] {
  const templates = new Map<string, JacpackTemplate>();
  for (const rawLine of output.split("\n")) {
    const line = rawLine.replace(/\x1b\[[0-9;]*m/g, "").trim();
    if (!line) continue;
    const m = line.match(/^[-•*\s]*([A-Za-z0-9._\-/]+)\s*:\s*(.+)$/);
    if (!m) continue;

    const name = m[1]!.trim();
    const description = m[2]!.trim();
    if (!name || !description) continue;
    if (/^(available|template|templates)$/i.test(name)) continue;

    templates.set(name, { name, description });
  }
  return [...templates.values()];
}

async function listJacpacks(jacBin: string): Promise<JacpackListResult> {
  const attempts: string[][] = [
    ["create", "--list_jacpacks"],
    ["jacpack", "list"],
  ];

  let lastError = "";
  for (const args of attempts) {
    try {
      const { stdout = "", stderr = "" } = await execFileAsync(jacBin, args, {
        timeout: 30000,
      });
      const combined = `${stdout}\n${stderr}`;
      const templates = parseJacpackTemplates(combined);
      if (templates.length > 0) return { templates };

      const compact = combined.toLowerCase();
      if (compact.includes("no jacpack templates") || compact.includes("no templates")) {
        return { templates: [] };
      }
      lastError = `No parseable template rows from: ${jacBin} ${args.join(" ")}`;
    } catch (e: any) {
      const out = `${e?.stdout ?? ""}${e?.stderr ?? ""}`.trim();
      lastError = out || e?.message || `Failed: ${jacBin} ${args.join(" ")}`;
    }
  }

  return { templates: [], error: lastError || "Could not list jacpack templates." };
}

async function listJacpacksCached(jacBin: string): Promise<JacpackTemplate[]> {
  const now = Date.now();
  if (
    jacpackCache &&
    jacpackCache.jacBin === jacBin &&
    now - jacpackCache.fetchedAt < JACPACK_CACHE_TTL_MS
  ) {
    return jacpackCache.templates;
  }

  const { templates } = await listJacpacks(jacBin);
  jacpackCache = { jacBin, fetchedAt: now, templates };
  return templates;
}

async function createArgumentCompletions(
  argumentPrefix: string,
): Promise<CreateArgCompletion[] | null> {
  const jacBin = findJacBinary();
  const templates = jacBin ? await listJacpacksCached(jacBin) : [];

  const normalized = argumentPrefix.replace(/^\s+/, "");
  const hasTrailingSpace = /\s$/.test(normalized);
  const trimmed = normalized.trim();
  const tokens = trimmed ? trimmed.split(/\s+/) : [];

  const buildValue = (parts: string[]): string => parts.join(" ");

  const templateSuggestions = (
    prefixParts: string[],
    templatePrefix: string,
  ): CreateArgCompletion[] => {
    const lowerPrefix = templatePrefix.toLowerCase();
    return templates
      .filter((t) =>
        !lowerPrefix
          ? true
          : t.name.toLowerCase().includes(lowerPrefix) ||
            t.description.toLowerCase().includes(lowerPrefix),
      )
      .slice(0, 40)
      .map((t) => ({
        value: buildValue([...prefixParts, t.name]),
        label: t.name,
        description: t.description,
      }));
  };

  const flagSuggestions = (prefixParts: string[], flagPrefix = ""): CreateArgCompletion[] => {
    const lowerPrefix = flagPrefix.toLowerCase();
    const flags = [
      {
        flag: "--use",
        label: "--use",
        description: "Choose a jacpack template",
      },
      {
        flag: "--force",
        label: "--force",
        description: "Overwrite existing project directory",
      },
      {
        flag: "-f",
        label: "-f",
        description: "Alias for --force",
      },
    ];

    return flags
      .filter((f) => (!lowerPrefix ? true : f.flag.startsWith(lowerPrefix)))
      .map((f) => ({
        value: buildValue([...prefixParts, f.flag]),
        label: f.label,
        description: f.description,
      }));
  };

  const currentToken = hasTrailingSpace ? "" : (tokens[tokens.length - 1] ?? "");
  const previousToken = hasTrailingSpace
    ? (tokens[tokens.length - 1] ?? "")
    : (tokens[tokens.length - 2] ?? "");

  // Completing template name after --use
  if (previousToken === "--use") {
    const prefixParts = hasTrailingSpace ? tokens : tokens.slice(0, -1);
    const items = templateSuggestions(prefixParts, currentToken);
    return items.length > 0 ? items : null;
  }

  // Typing a flag token (e.g. --f)
  if (currentToken.startsWith("-")) {
    const prefixParts = hasTrailingSpace ? tokens : tokens.slice(0, -1);
    const items = flagSuggestions(prefixParts, currentToken);
    return items.length > 0 ? items : null;
  }

  // Right after `/create ` with no args yet
  if (!trimmed) {
    const items: CreateArgCompletion[] = [
      ...templateSuggestions(["--use"], ""),
      ...flagSuggestions([], ""),
    ];
    return items.length > 0 ? items : null;
  }

  // After a completed token and trailing space, offer likely next tokens.
  if (hasTrailingSpace) {
    const hasUse = tokens.includes("--use");
    const hasForce = tokens.includes("--force") || tokens.includes("-f");

    const items: CreateArgCompletion[] = [];
    if (!hasUse) {
      items.push(...templateSuggestions([...tokens, "--use"], ""));
      items.push({
        value: buildValue([...tokens, "--use"]),
        label: "--use",
        description: "Choose a jacpack template",
      });
    }
    if (!hasForce) {
      items.push({
        value: buildValue([...tokens, "--force"]),
        label: "--force",
        description: "Overwrite existing project directory",
      });
    }

    return items.length > 0 ? items : null;
  }

  return null;
}

function registerCreate({ pi }: CommandContext): void {
  pi.registerCommand("create", {
    description:
      "Scaffold a new Jac project via `jac create`. Usage: /create [name] [--use template]",
    getArgumentCompletions: async (argumentPrefix) =>
      createArgumentCompletions(argumentPrefix),
    handler: async (args, ctx) => {
      const jacBin = findJacBinary();
      if (!jacBin) {
        ctx.ui.notify(
          "jac binary not found. Install with: pip install jaclang",
          "error",
        );
        return;
      }

      const parts = args.trim().split(/\s+/).filter(Boolean);
      const positional: string[] = [];
      let useTemplate: string | undefined;
      let force = false;

      for (let i = 0; i < parts.length; i++) {
        if (parts[i] === "--use" && parts[i + 1]) {
          useTemplate = parts[++i];
        } else if (parts[i] === "--force" || parts[i] === "-f") {
          force = true;
        } else if (!parts[i]!.startsWith("-")) {
          positional.push(parts[i]!);
        }
      }

      let projectName: string | undefined = positional[0];
      const jacpackList = await listJacpacks(jacBin);
      const knownTemplates = new Set(jacpackList.templates.map((t) => t.name));

      // Shorthand support:
      //   /create client            -> template=client, default project name prompt
      //   /create myapp client      -> project=myapp, template=client
      if (!useTemplate && knownTemplates.size > 0 && positional.length > 0) {
        const last = positional[positional.length - 1]!;
        if (positional.length === 1 && knownTemplates.has(last)) {
          useTemplate = last;
          projectName = undefined;
        } else if (positional.length >= 2 && knownTemplates.has(last)) {
          useTemplate = last;
          projectName = positional[0];
        }
      }

      // If no template specified, show TUI picker (or fallback manual input)
      if (!useTemplate && ctx.hasUI) {
        const templates = jacpackList.templates;

        if (templates.length === 0) {
          const suffix = jacpackList.error ? `\n\nReason: ${jacpackList.error}` : "";
          ctx.ui.notify(
            "Could not auto-list jacpack templates. You can still enter a template manually (e.g. default, client, fullstack)." +
              suffix,
            "warning",
          );

          const manual = await ctx.ui.editor(
            "Template name (leave blank for default template):",
            "",
          );
          if (manual === undefined) {
            ctx.ui.notify("Create cancelled.", "info");
            return;
          }
          const typed = manual.trim();
          if (typed) useTemplate = typed;
        } else {
          const options = templates.map((t) =>
            t.description ? `${t.name} — ${t.description}` : t.name,
          );
          const picked = await ctx.ui.select("Scaffold a new Jac project", options);

          if (picked === undefined) {
            ctx.ui.notify("Create cancelled.", "info");
            return;
          }
          useTemplate = picked.split(" — ")[0]!.trim();
        }
      }

      // If no project name, ask for one
      if (!projectName && ctx.hasUI) {
        const nameInput = await ctx.ui.editor(
          "Project name (default: jactastic):",
          "jactastic",
        );
        projectName = nameInput?.trim() || "jactastic";
      } else if (!projectName) {
        projectName = "jactastic";
      }

      // Build and run the jac create command
      const cmdArgs = ["create", projectName];
      if (useTemplate) cmdArgs.push("--use", useTemplate);
      if (force) cmdArgs.push("--force");

      ctx.ui.setStatus("jac", `Creating ${projectName}...`);
      try {
        const { stdout, stderr } = await execFileAsync(jacBin, cmdArgs, {
          cwd: ctx.cwd,
          timeout: 120_000,
        });
        ctx.ui.setStatus("jac", "");

        const output = (stdout + stderr).trim();
        ctx.ui.notify(output || `Project ${projectName} created.`, "success" as any);
      } catch (e: any) {
        ctx.ui.setStatus("jac", "");
        const output = (e.stdout || "") + (e.stderr || "");
        ctx.ui.notify(
          output?.trim() || e.message || `jac create failed`,
          "error",
        );
      }
    },
  });
}

// ──── /plan ──────────────────────────────────────────────────────────

function registerJacPlan({ pi }: CommandContext): void {
  pi.registerCommand("plan", {
    description:
      "Toggle Plan mode, or enter plan mode and send a prompt in one action. Usage: /plan [prompt]",
    handler: async (args, ctx) => {
      const prompt = args.trim();
      if (!prompt) {
        toggleJacPlanMode(pi, ctx);
        return;
      }

      // Prompt provided — enable plan mode if needed, then send the prompt
      enableJacPlanMode(pi, ctx);
      pi.sendUserMessage(prompt);
    },
  });
}

// ──── /clear ─────────────────────────────────────────────────────────

function registerClearScreen({ pi }: CommandContext): void {
  const clearHandler = async (): Promise<void> => {
    // Clear visible screen + scrollback and move cursor to top-left.
    process.stdout.write("\x1b[2J\x1b[3J\x1b[H");
  };

  pi.registerCommand("clear", {
    description: "Clear the terminal screen and keep the current session/context.",
    handler: clearHandler,
  });

  pi.registerCommand("new", {
    description: "Alias for /clear.",
    handler: clearHandler,
  });
}

// ──── /subagent-model ───────────────────────────────────────────────

function registerJacSubagentModel({ pi }: CommandContext): void {
  pi.registerCommand("subagent-model", {
    description:
      'List or set subagents.agentOverrides.<agent>.model in jackal/settings.json. Type agent name manually; after "agent " tab completes models only.',
    getArgumentCompletions: (argumentPrefix) => {
      const items = subagentModelCompletions(argumentPrefix);
      if (!items) return null;
      return items.map(({ value, label }) => ({ value, label }));
    },
    handler: async (args, ctx) => {
      const trimmed = args.trim();
      const { data: parsed, error: readErr } = readJackalSettingsParsed();

      if (!trimmed) {
        if (!parsed) {
          ctx.ui.notify(
            readErr ||
              "Could not read jackal/settings.json. Use jackal.sh so PI_CODING_AGENT_DIR is set, or export PI_CODING_AGENT_DIR.",
            "warning",
          );
          return;
        }
        ctx.ui.notify(describeSubagentOverrides(parsed), "info");
        return;
      }

      const parts = trimmed.split(/\s+/).filter(Boolean);
      const agent = parts[0]!;
      if (!/^[\w.-]+$/.test(agent)) {
        ctx.ui.notify(`Invalid agent name: ${agent}`, "error");
        return;
      }

      if (parts.length === 1) {
        if (!ctx.hasUI) {
          ctx.ui.notify(
            "Usage: /subagent-model <agent> <provider/model-id> (no TUI in this mode) or run with an interactive terminal.",
            "warning",
          );
          return;
        }
        const spec = await pickSubagentModelSpec(agent, ctx);
        if (!spec) {
          ctx.ui.notify("Cancelled — no change.", "info");
          return;
        }
        const result = setSubagentModelPin(agent, spec);
        if (!result.ok) {
          ctx.ui.notify(result.error || "Failed to write settings", "error");
          return;
        }
        ctx.ui.notify(
          `Saved model for \`${agent}\`: ${spec}\nUse /reload if the pin does not apply immediately.`,
          "info",
        );
        return;
      }

      if (parts[1] === "clear") {
        const result = clearSubagentModelPin(agent);
        if (!result.ok) {
          ctx.ui.notify(result.error || "Failed to write settings", "error");
          return;
        }
        ctx.ui.notify(
          `Cleared model override for \`${agent}\` (if any). Use /reload if needed.`,
          "info",
        );
        return;
      }

      const modelSpec = parts.slice(1).join(" ").trim();
      if (!modelSpec) {
        ctx.ui.notify("Model id cannot be empty.", "error");
        return;
      }
      const result = setSubagentModelPin(agent, modelSpec);
      if (!result.ok) {
        ctx.ui.notify(result.error || "Failed to write settings", "error");
        return;
      }
      ctx.ui.notify(
        `Saved model for \`${agent}\`: ${modelSpec}\nUse /reload if the pin does not apply immediately.`,
        "info",
      );
    },
  });
}

// ──── /commit ────────────────────────────────────────────────────────────

function registerNextAgentSmoke({ pi }: CommandContext): void {
  pi.registerCommand("next-agent-smoke", {
    description:
      "Run Phase-0 in-process runtime smoke for the new Jackal agent.",
    handler: async (_args, ctx) => {
      ctx.ui.setStatus("jackal-next", "Running smoke...");
      try {
        const result = await runNextAgentSmoke(ctx.cwd);
        if (result.ok) {
          const events = result.eventTypes.length
            ? result.eventTypes.join(", ")
            : "(no events captured)";
          ctx.ui.notify(
            `✅ next-agent smoke passed\nEvents (${result.eventTypes.length}): ${events}\nStore mutations: ${result.snapshotCount}\nUI mutations: ${result.dialogCount}`,
            "info",
          );
        } else {
          ctx.ui.notify(
            `❌ next-agent smoke failed\n${result.error || "Unknown error"}`,
            "error",
          );
        }
      } finally {
        ctx.ui.setStatus("jackal-next", "");
      }
    },
  });
}

function registerJackalShell({ pi }: CommandContext): void {
  pi.registerCommand("jackal-shell", {
    description:
      "Launch Jackal Ink shell via jac-ink (jac tui shell.cl.jac).",
    handler: async (_args, ctx) => {
      const outDir = join(ctx.cwd, ".jac", "jackal-shell");
      mkdirSync(outDir, { recursive: true });

      // Copy shell template
      const __dirname = dirname(fileURLToPath(import.meta.url));
      const templatePath = join(__dirname, "..", "..", "agent-next", "templates", "shell.cl.jac");
      if (!existsSync(templatePath)) {
        ctx.ui.notify(`Shell template not found: ${templatePath}`, "error");
        return;
      }

      const shellSrc = await import("node:fs").then((fs) =>
        fs.readFileSync(templatePath, "utf-8"),
      );

      // Write package.json
      const pkgJson = {
        name: "jackal-shell",
        private: true,
        type: "module",
        scripts: { start: "jac tui shell.cl.jac --run" },
        dependencies: {
          ink: "^7.0.3",
          react: "^19.2.4",
          "@earendil-works/pi-agent-core": "0.75.4",
          "@earendil-works/pi-ai": "0.75.4",
        },
      };

      writeFileSync(join(outDir, "shell.cl.jac"), shellSrc, "utf-8");
      writeFileSync(
        join(outDir, "package.json"),
        JSON.stringify(pkgJson, null, 2) + "\n",
        "utf-8",
      );

      ctx.ui.notify(
        `Shell template: ${outDir}/shell.cl.jac\nRun: ./jackal.sh  (or: cd agent-next && jac tui templates/shell.cl.jac --install --run)`,
        "info",
      );
    },
  });
}

function registerCommit({ pi }: CommandContext): void {
  pi.registerCommand("commit", {
    description:
      "Review git changes and commit with a conventional message. Usage: /commit [message]",
    handler: async (args, ctx) => {
      const userMessage = args.trim();

      const prompt = [
        "The user invoked `/commit" +
          (userMessage ? ` "${userMessage}"` : "") +
          "`. Follow the **commit-review-skill** workflow:",
        "",
        "## 1. Inspect changes",
        "Run these in parallel:",
        "  - `git diff --cached`  (staged)",
        "  - `git diff`           (unstaged)",
        "  - `git status`         (untracked files)",
        "  - `git log -5 --oneline` (recent convention)",
        "",
        "## 2. Review checklist",
        "Check all changes for:",
        "  - Bugs or logic errors",
        "  - Security issues (secrets, credentials, API keys)",
        "  - Missing error handling",
        "  - Incomplete implementations",
        "  - Files that should be in .gitignore",
        "",
        "## 3. Commit",
        "If no issues:",
        "  1. Stage relevant files: `git add .` (or specific paths if only part should ship)",
        "  2. Confirm what will commit: `git diff --cached`",
        "  3. Commit with a descriptive message:",
        userMessage
          ? `     Use this message verbatim:\n     \"${userMessage}\"`
          : "     Generate a message following project convention (feat:/fix:/docs:/refactor:/chore:/etc.)",
        "     Pass the message via HEREDOC:",
        "     ```",
        "     git commit -m \"$(cat <<'EOF'",
        "     <type>: short summary",
        "     EOF",
        "     )\"",
        "     ```",
        "  4. Show the result: `git log -1 --stat`",
        "",
        "If issues are found, report them clearly and ask whether to proceed. Do not commit until confirmed.",
        "",
        "## Safety (never unless user explicitly asks)",
        "  - Do not update git config",
        "  - Do not use --no-verify, --no-gpg-sign, or force push to main/master",
        "  - Do not amend unless the user requested it and the last commit was yours and unpushed",
        "  - Do not commit .env, credentials, or secrets — warn instead",
        "",
        "## After committing",
        "Return a brief summary: commit hash, message, files changed, and any follow-up (e.g. push).",
      ].join("\n");

      pi.sendUserMessage(prompt);
    },
  });
}

// ──── Register all commands ──────────────────────────────────────────────

export function registerCommands(ctx: CommandContext): void {
  registerJacDoctor(ctx);
  registerJacCheck(ctx);
  registerJacFix(ctx);
  registerJacVerbose(ctx);
  registerJacOsp(ctx);
  registerRefactor(ctx);
  registerCreate(ctx);
  registerJacPlan(ctx);
  registerClearScreen(ctx);
  registerJacSubagentModel(ctx);
  registerNextAgentSmoke(ctx);
  registerJackalShell(ctx);
  registerCommit(ctx);
}
