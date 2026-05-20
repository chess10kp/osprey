// ────────────────────────────────────────────────────────────────────────────
// Plan mode — tool whitelists, step extraction, status tracking, toggle.
// ────────────────────────────────────────────────────────────────────────────

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import type { JacPlanStep } from "./types.js";
import { state } from "./types.js";

// ──── Tool whitelists ────────────────────────────────────────────────────

export const JAC_PLAN_TOOLS = [
  "validate_jac",
  "check_syntax",
  "explain_error",
  "search_docs",
  "get_resource",
  "list_examples",
  "get_example",
  "get_ast",
  "read",
  "bash",
];

export const JAC_EXECUTE_TOOLS = [
  "validate_jac",
  "check_syntax",
  "run_jac",
  "explain_error",
  "format_jac",
  "lint_jac",
  "search_docs",
  "get_resource",
  "list_examples",
  "get_example",
  "get_ast",
  "py_to_jac",
  "jac_to_py",
  "jac_to_js",
  "graph_visualize",
  "read",
  "write",
  "edit",
  "bash",
];

// ──── Step extraction ────────────────────────────────────────────────────

export function cleanPlanStep(text: string): string {
  let cleaned = text
    .replace(/\*{1,2}([^*]+)\*{1,2}/g, "$1")
    .replace(/`([^`]+)`/g, "$1")
    .replace(
      /^(Use|Run|Execute|Create|Write|Read|Check|Verify|Update|Modify|Add|Remove|Delete|Fix|Apply)\s+(the\s+)?/i,
      "",
    )
    .replace(/\s+/g, " ")
    .trim();

  if (cleaned.length > 0) {
    cleaned = cleaned.charAt(0).toUpperCase() + cleaned.slice(1);
  }
  if (cleaned.length > 60) {
    cleaned = `${cleaned.slice(0, 57)}...`;
  }
  return cleaned;
}

/** Extract numbered plan steps from an assistant message (after a `Plan:` header). */
export function extractPlanSteps(message: string): JacPlanStep[] {
  const items: JacPlanStep[] = [];
  const headerMatch = message.match(/\*{0,2}Plan:\*{0,2}\s*\n/i);
  if (!headerMatch) return items;

  const planSection = message.slice(message.indexOf(headerMatch[0]) + headerMatch[0].length);
  const numberedPattern = /^\s*(\d+)[.)]\s+\*{0,2}([^*\n]+)/gm;

  for (const match of planSection.matchAll(numberedPattern)) {
    const text = match[2]!.trim().replace(/\*{1,2}$/, "").trim();
    if (text.length > 5 && !text.startsWith("`") && !text.startsWith("/") && !text.startsWith("-")) {
      const cleaned = cleanPlanStep(text);
      if (cleaned.length > 3) {
        items.push({ step: items.length + 1, text: cleaned, completed: false });
      }
    }
  }
  return items;
}

/** Extract `[DONE:n]` markers from a message. */
export function extractDoneSteps(message: string): number[] {
  const steps: number[] = [];
  for (const match of message.matchAll(/\[DONE:(\d+)\]/gi)) {
    const step = Number(match[1]);
    if (Number.isFinite(step)) steps.push(step);
  }
  return steps;
}

/** Mark completed steps in the plan and return the number newly completed. */
export function markCompletedSteps(text: string, items: JacPlanStep[]): number {
  const doneSteps = extractDoneSteps(text);
  for (const step of doneSteps) {
    const item = items.find((t) => t.step === step);
    if (item) item.completed = true;
  }
  return doneSteps.length;
}

// ──── Enable / Disable helpers ───────────────────────────────────────────

/** Enable plan mode if it is not already active. Returns true if it was newly enabled. */
export function enableJacPlanMode(pi: ExtensionAPI, ctx: any): boolean {
  const alreadyEnabled = state.planMode?.enabled ?? false;
  const alreadyExecuting = state.planMode?.executing ?? false;
  if (alreadyEnabled || alreadyExecuting) return false;

  state.planMode = { enabled: true, executing: false, todos: [] };
  pi.setActiveTools(JAC_PLAN_TOOLS);
  pi.appendEntry("jackal:plan_mode", { enabled: true, todos: [], ts: Date.now() });
  ctx.ui.notify("Plan mode enabled. Read-only MCP tools only.", "info");
  updatePlanStatus(ctx);
  return true;
}

// ──── Status display ─────────────────────────────────────────────────────

/** Update the TUI status bar and todo widget based on current plan mode state. */
export function updatePlanStatus(ctx: any): void {
  const planMode = state.planMode;
  if (!planMode) {
    ctx.ui.setStatus("plan", undefined);
    ctx.ui.setWidget("plan-todos", undefined);
    return;
  }

  if (planMode.executing && planMode.todos.length > 0) {
    const completed = planMode.todos.filter((t) => t.completed).length;
    ctx.ui.setStatus("plan", ctx.ui.theme.fg("accent", `📋 ${completed}/${planMode.todos.length}`));
  } else if (planMode.enabled) {
    ctx.ui.setStatus("plan", ctx.ui.theme.fg("warning", "⏸ plan"));
  } else {
    ctx.ui.setStatus("plan", undefined);
  }

  if (planMode.executing && planMode.todos.length > 0) {
    const lines = planMode.todos.map((item) => {
      if (item.completed) {
        return (
          ctx.ui.theme.fg("success", "☑ ") +
          ctx.ui.theme.fg("muted", ctx.ui.theme.strikethrough(item.text))
        );
      }
      return `${ctx.ui.theme.fg("muted", "☐ ")}${item.text}`;
    });
    ctx.ui.setWidget("plan-todos", lines);
  } else {
    ctx.ui.setWidget("plan-todos", undefined);
  }
}

/** Toggle plan mode on/off. */
export function toggleJacPlanMode(pi: ExtensionAPI, ctx: any): void {
  const currentEnabled = state.planMode?.enabled ?? false;
  const currentExecuting = state.planMode?.executing ?? false;

  if (!currentEnabled && !currentExecuting) {
    // Enable plan mode
    state.planMode = { enabled: true, executing: false, todos: [] };
    pi.setActiveTools(JAC_PLAN_TOOLS);
    pi.appendEntry("jackal:plan_mode", { enabled: true, todos: [], ts: Date.now() });
    ctx.ui.notify("Plan mode enabled. Read-only MCP tools only.", "info");
  } else {
    // Disable plan mode (either planning or executing)
    state.planMode = undefined;
    pi.setActiveTools(JAC_EXECUTE_TOOLS);
    pi.appendEntry("jackal:plan_mode", { enabled: false, todos: [], ts: Date.now() });
    ctx.ui.notify("Plan mode disabled. Full tool access restored.", "info");
  }
  updatePlanStatus(ctx);
}
