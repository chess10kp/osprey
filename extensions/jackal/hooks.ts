// ────────────────────────────────────────────────────────────────────────────
// Hooks — event handler registrations for the Jackal extension.
//
// Registers:
//   • tool_result   — track edited .jac files for end-of-run autocheck
//   • agent_end     — run autocheck + plan-mode completion check
//   • session_start — restore plan mode state, capture ExtensionContext
//   • session_shutdown — reset all session state
//   • turn_end      — mark completed plan steps from [DONE:n] markers
// ────────────────────────────────────────────────────────────────────────────

import type { ExtensionAPI, ToolResultEvent } from "@earendil-works/pi-coding-agent";
import {
  isEditToolResult,
  isWriteToolResult,
} from "@earendil-works/pi-coding-agent";
import { dirname } from "node:path";

import { state, fingerprintErrors, getVerboseOverride } from "./types.js";
import { findJacBinary, runJacCheck, formatDiagnostics } from "./check.js";
import {
  JAC_PLAN_TOOLS,
  JAC_EXECUTE_TOOLS,
  extractPlanSteps,
  markCompletedSteps,
  updatePlanStatus,
} from "./plan-mode.js";
import { setLatestExtensionContext } from "./settings.js";
import { loadProjectConfig, getConfig, clearConfig, formatConfig } from "./config.js";

export interface HookContext {
  pi: ExtensionAPI;
  isVerbose: () => boolean;
}

/** Check if autocheck is enabled (flag or .jackal config). */
function isAutocheckEnabled(pi: ExtensionAPI): boolean {
  // Explicit flag override (from /jac-check toggle) wins
  const flag = pi.getFlag("jac-autocheck");
  if (flag !== undefined) return Boolean(flag);
  // Fall back to .jackal config
  return getConfig().autocheck;
}

export function registerHooks({ pi }: HookContext): void {
  // ──── Track edited .jac files for end-of-run auto-check ──────────────
  pi.on("tool_result", async (event: ToolResultEvent) => {
    if (event.isError) return;
    if (!isAutocheckEnabled(pi)) return;

    let path: string | undefined;
    if (isWriteToolResult(event)) {
      path = (event.input as { path?: string }).path;
    } else if (isEditToolResult(event)) {
      path = (event.input as { path?: string }).path;
    }
    if (!path || !path.endsWith(".jac")) return;

    state.workingFile = path;
    state.pendingCheckFiles.add(path);
    pi.appendEntry("jackal:working_file", { path, ts: Date.now() });
  });

  // ──── End-of-run auto-check ──────────────────────────────────────────
  pi.on("agent_end", async (event, ctx) => {
    // ── Plan mode: check completion ──────────────────────────────────
    const planMode = state.planMode;
    if (planMode) {
      if (planMode.executing && planMode.todos.length > 0) {
        if (planMode.todos.every((t) => t.completed)) {
          const completedList = planMode.todos
            .map((t) => `~~${t.text}~~`)
            .join("\n");
          pi.sendMessage(
            {
              customType: "jackal:plan_complete",
              content: `**Plan Complete!** ✓\n\n${completedList}`,
              display: true,
            },
            { triggerTurn: false },
          );
          state.planMode = undefined;
          pi.setActiveTools(JAC_EXECUTE_TOOLS);
          updatePlanStatus(ctx);
          pi.appendEntry("jackal:plan_mode", {
            enabled: false,
            todos: [],
            ts: Date.now(),
          });
        }
        // Don't run autocheck if plan execution is still in progress
        return;
      }

      // Plan mode (not executing) — extract todos from assistant message
      if (planMode.enabled && ctx?.hasUI) {
        const lastAssistant = [...(event.messages || [])]
          .reverse()
          .find((m: any) => m.role === "assistant") as any;
        if (lastAssistant) {
          const text = Array.isArray(lastAssistant.content)
            ? lastAssistant.content
                .filter((c: any) => c.type === "text")
                .map((c: any) => c.text)
                .join("\n")
            : (lastAssistant.content as string);
          const extracted = extractPlanSteps(text);
          if (extracted.length > 0) {
            planMode.todos = extracted;
          }
        }

        if (planMode.todos.length > 0) {
          const todoListText = planMode.todos
            .map((t, i) => `${i + 1}. ☐ ${t.text}`)
            .join("\n");
          pi.sendMessage(
            {
              customType: "jackal:plan_todos",
              content: `**Plan Steps (${planMode.todos.length}):**\n\n${todoListText}`,
              display: true,
            },
            { triggerTurn: false },
          );

          const choice = await ctx.ui.select("Plan mode - what next?", [
            planMode.todos.length > 0
              ? "Execute the plan (track progress)"
              : "Execute the plan",
            "Stay in plan mode",
            "Refine the plan",
          ]);

          if (choice?.startsWith("Execute")) {
            planMode.enabled = false;
            planMode.executing = planMode.todos.length > 0;
            pi.setActiveTools(JAC_EXECUTE_TOOLS);
            updatePlanStatus(ctx);
            pi.appendEntry("jackal:plan_mode", {
              enabled: false,
              executing: planMode.executing,
              todos: planMode.todos,
              ts: Date.now(),
            });

            const execMessage =
              planMode.todos.length > 0
                ? `Execute the plan. Start with: ${planMode.todos[0]!.text}\n\nUse the available Jac MCP tools as needed (validate_jac, check_syntax, run_jac, search_docs, get_ast, graph_visualize). Mark steps complete with [DONE:n] tags.`
                : "Execute the plan you just created.";
            pi.sendMessage(
              {
                customType: "jackal:plan_execute",
                content: execMessage,
                display: true,
              },
              { triggerTurn: true },
            );
          } else if (choice === "Refine the plan") {
            const refinement = await ctx.ui.editor("Refine the plan:", "");
            if (refinement?.trim()) {
              pi.sendUserMessage(refinement.trim());
            }
          }
        }
      }
      return; // Don't run autocheck during plan mode agent_end
    }

    // ── Autocheck: run jac check on pending files ────────────────────
    if (!isAutocheckEnabled(pi)) return;
    if (state.pendingCheckFiles.size === 0) return;

    const files = [...state.pendingCheckFiles];
    state.pendingCheckFiles.clear();

    const jacBin = findJacBinary();
    if (!jacBin) return;

    const { diagnostics } = await runJacCheck(
      jacBin,
      dirname(files[0]!),
      files,
    );
    const errors = diagnostics.filter((d) => d.severity === "error");

    if (errors.length === 0) {
      for (const f of files) {
        state.attempts.delete(f);
        state.lastErrorFingerprint.delete(f);
      }
      return;
    }

    const summary = formatDiagnostics(errors);
    const fingerprintKey = files.sort().join("|");
    const fp = fingerprintErrors(errors);
    const previousFingerprint = state.lastErrorFingerprint.get(fingerprintKey);
    state.lastErrorFingerprint.set(fingerprintKey, fp);

    // No-progress short-circuit
    if (previousFingerprint && previousFingerprint === fp) {
      pi.sendMessage({
        customType: "jackal:autocheck",
        content:
          `⚠️  Auto-check after edits to ${files.map((f) => `\`${f}\``).join(", ")}: the same ${errors.length} error(s) are still reported (no progress).\n` +
          `Stopping the auto-fix loop. These may be false positives from \`jac check\`'s type checker.\n\n` +
          `Verify functional correctness with \`jac lint\` and \`jac run\` before assuming they're real bugs:\n${summary}`,
        display: true,
      });
      state.attempts.delete(fingerprintKey);
      return;
    }

    const attempts = (state.attempts.get(fingerprintKey) || 0) + 1;
    state.attempts.set(fingerprintKey, attempts);

    const cap = getConfig().maxFixAttempts;
    if (attempts > cap) {
      pi.sendMessage({
        customType: "jackal:autocheck",
        content:
          `⚠️  Auto-check still failing after ${cap} attempts on ${files.map((f) => `\`${f}\``).join(", ")}. Stopping the auto-fix loop.\n` +
          `If \`jac lint\` passes and the file runs, these are likely false positives — leave them alone.\n\n${summary}`,
        display: true,
      });
      state.attempts.delete(fingerprintKey);
      return;
    }

    const prompt = [
      `Auto-check after this turn's edits to ${files.map((f) => `\`${f}\``).join(", ")} (attempt ${attempts}/${cap}) reported ${errors.length} error(s):`,
      "",
      summary,
      "",
      "Before editing: consider whether these are *real* bugs or false positives.",
      "  • Run `jac lint` and `jac run` first — if both succeed, the errors are likely false positives",
      "    from `jac check`'s type checker (common with external/JS interop, React events, etc.).",
      "  • If the errors look like type-checker limitations rather than real bugs, STOP and tell the",
      "    user — do not keep editing. The auto-fix loop will halt automatically if your next edit",
      "    produces the same error set.",
      "",
      "If they are real bugs: read each file at the reported lines, apply focused fixes, then call the",
      "`validate_jac` MCP tool to verify. Use `explain_error` for unfamiliar codes. No unrelated refactors.",
    ].join("\n");
    pi.sendUserMessage(prompt);
  });

  // ──── session_start — load .jackal config, restore plan mode, capture ctx ─
  pi.on("session_start", async (_event, ctx) => {
    setLatestExtensionContext(ctx);

    // Load .jackal project config (walks up from cwd)
    const config = loadProjectConfig(ctx.cwd);

    // Log config source for diagnostics
    if (config.configPath) {
      pi.appendEntry("jackal:config_loaded", {
        path: config.configPath,
        autocheck: config.autocheck,
        verbose: config.verbose,
        plan: config.plan,
        maxFixAttempts: config.maxFixAttempts,
        mermaid: config.mermaid,
        notify: config.notify,
        ts: Date.now(),
      });
    }

    // Initialize plan mode from .jackal config or flag (flag wins)
    const planFromConfig = config.plan === true;
    if (pi.getFlag("plan") === true || planFromConfig) {
      state.planMode = { enabled: true, executing: false, todos: [] };
      pi.setActiveTools(JAC_PLAN_TOOLS);
      updatePlanStatus(ctx);
    }

    // Restore persisted state
    const entries = ctx.sessionManager?.getEntries() || [];
    const planModeEntry = entries
      .filter((e: any) => e.type === "custom" && e.customType === "jackal:plan_mode")
      .pop() as any;

    if (planModeEntry?.data) {
      state.planMode = {
        enabled: planModeEntry.data.enabled,
        executing: planModeEntry.data.executing ?? false,
        todos: planModeEntry.data.todos ?? [],
      };
      if (state.planMode.enabled) {
        pi.setActiveTools(JAC_PLAN_TOOLS);
      } else if (state.planMode.executing) {
        pi.setActiveTools(JAC_EXECUTE_TOOLS);
      }
      updatePlanStatus(ctx);
    }
  });

  // ──── turn_end — mark completed plan steps ──────────────────────────
  pi.on("turn_end", async (event, ctx) => {
    const planMode = state.planMode;
    if (!planMode || !planMode.executing || planMode.todos.length === 0) return;

    const message = event.message;
    if (!message || message.role !== "assistant") return;

    const text = Array.isArray(message.content)
      ? message.content
          .filter((c: any) => c.type === "text")
          .map((c: any) => c.text)
          .join("\n")
      : (message.content as string);

    if (markCompletedSteps(text, planMode.todos) > 0) {
      updatePlanStatus(ctx);
      pi.appendEntry("jackal:plan_mode", {
        enabled: planMode.enabled,
        executing: planMode.executing,
        todos: planMode.todos,
        ts: Date.now(),
      });
    }
  });

  // ──── session_shutdown — reset all state ────────────────────────────
  pi.on("session_shutdown", async () => {
    setLatestExtensionContext(null);
    clearConfig();
    state.attempts.clear();
    state.lastErrorFingerprint.clear();
    state.pendingCheckFiles.clear();
    state.workingFile = undefined;
    state.planMode = undefined;
  });
}
