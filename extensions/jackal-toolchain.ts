// ────────────────────────────────────────────────────────────────────────────
// Jackal toolchain extension — entry point
//
// Jackal does NOT register its own jac_check / jac_run / jac_test tools.
// Those are provided (with much richer behaviour) by the official `jac mcp`
// server, which is wired up in jackal/mcp.json. This extension only adds:
//
//   • slash-command workflows  (/jac-doctor, /jac-check, /fix, /jac-verbose,
//     /osp, /create, /refactor, /plan, /subagent-model)
//   • an auto-check hook that re-validates a .jac file after every write/edit
//   • lightweight session state: current working file + per-file fix attempts + plan mode
//
// All LLM-callable behaviour for validation, transpilation, examples, etc.
// goes through the MCP tools (validate_jac, run_jac, explain_error,
// list_examples, get_example, search_docs, get_resource, …).
//
// Architecture:
//   jackal/types.ts       — shared interfaces + state singleton
//   jackal/check.ts       — local jac check helpers (parse, find binary, run)
//   jackal/settings.ts    — settings file I/O + subagent model pin management
//   jackal/plan-mode.ts   — plan mode constants, step extraction, status, toggle
//   jackal/commands.ts    — all slash command registrations
//   jackal/hooks.ts       — all event handler registrations
// ────────────────────────────────────────────────────────────────────────────

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

import { getVerboseOverride } from "./jackal/types.js";
import { registerCommands } from "./jackal/commands.js";
import { registerHooks } from "./jackal/hooks.js";

export default function (pi: ExtensionAPI) {
  // ──── Flags ──────────────────────────────────────────────────────────
  pi.registerFlag("jac-verbose", {
    description:
      "Show full jac check output and per-attempt detail in slash commands.",
    type: "boolean",
    default: false,
  });
  pi.registerFlag("jac-autocheck", {
    description:
      "Automatically run `jac check` after every write/edit of a .jac file.",
    type: "boolean",
    default: true,
  });
  pi.registerFlag("plan", {
    description:
      "Start in Plan mode (read-only exploration with Jac MCP).",
    type: "boolean",
    default: false,
  });

  const isVerbose = (): boolean =>
    getVerboseOverride() !== undefined
      ? getVerboseOverride()!
      : Boolean(pi.getFlag("jac-verbose"));

  // ──── Shared context ─────────────────────────────────────────────────
  const ctx = { pi, isVerbose };

  // ──── Register everything ────────────────────────────────────────────
  registerCommands(ctx);
  registerHooks(ctx);
}
