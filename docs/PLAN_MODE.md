# Plan Mode — Implementation Plan

## Overview

Plan mode is a dedicated exploration and planning workflow where the agent investigates the codebase with read-only tools and produces a structured implementation plan — it **cannot** edit files, run mutating shell commands, or modify task state.

This document specifies what needs to change across the Jackal codebase to reach nanocoder parity for plan mode.

## Current State

### What already works

1. **Mode enum** — `DevMode` includes `"plan"` in `src/agent/dev-mode.ts`
2. **Mode cycling** — Shift+Tab cycles through `normal → auto-accept → yolo → plan` in `shell.cl.jac`
3. **Tool blocking** — `PLAN_MODE_BLOCKED_TOOLS` blocks `write`, `edit`, `jac_format`, `jac_fix`, `jac_create`, `create_task`, `update_task`, `delete_task`, `format_jac`, `execute_command`
4. **System prompt injection** — `systemPromptForMode()` appends a plan-mode-specific system prompt section
5. **Status bar** — Shows `plan` label in yellow via `mode_color("plan")`
6. **`/plan <desc>` command** — Sends a structured planning prompt to the LLM
7. **Config** — `.jackal` supports `plan: true` (legacy) and `mode: "plan"` keys
8. **`beforeToolCall` hook** — In `agent-session.ts`, blocks plan-mode tools with a reason message
9. **Approval flow** — `shouldAutoApprove()` returns `true` for non-blocked tools in plan mode (they skip approval)

### What's missing (nanocoder parity)

| Area | Gap | Nanocoder reference |
|------|-----|-------------------|
| **Tool filtering** | `bash` is NOT blocked in plan mode — agent can run arbitrary commands | `execute_bash` is fully excluded in plan mode |
| **Tool filtering** | `glob`, `diagnostics`, `hover`, `definition`, `references`, `mermaid` work (good) — but no explicit guarantee they stay available | These are exploration tools — keep them |
| **Tool filtering** | MCP write tools may leak through (only `format_jac` and `execute_command` blocked) | All mutation tools excluded |
| **System prompt** | Plan mode prompt is minimal — doesn't guide the agent to produce structured output | Detailed instructions for investigation → structured plan → stop |
| **`/plan` command** | Does NOT auto-enter plan mode — user must Shift+Tab separately | Should auto-switch to plan mode |
| **Visual feedback** | No plan mode banner or prominent indicator — only a small label in status bar | Dedicated banner, changed prompt marker |
| **Plan → execute handoff** | No workflow to transition from plan to execution | Switch back to normal/yolo → agent has plan in context → executes |
| **Bash filtering** | `bash` tool has no plan-mode restrictions — agent could `rm -rf` while "planning" | All bash blocked in plan mode |
| **MCP tool filtering** | MCP tools added after boot don't get plan-mode filtering | Custom tool `readOnly` metadata checked |
| **Documentation** | AGENTS.md mentions plan mode but no detailed workflow docs | Full docs page |

---

## Implementation Plan

### Task 1: Backend — Expand plan mode tool blocking

**File:** `src/agent/dev-mode.ts`

**Changes:**

1. **Block `bash` entirely in plan mode.** The agent should not be able to run shell commands when planning. Add `"bash"` to `PLAN_MODE_BLOCKED_TOOLS`.

2. **Block additional MCP/write tools:**
   ```
   "jac_run",          # runs code — mutation risk
   "jac_test",         # runs tests — not a read-only operation
   "run_jac",          # MCP tool equivalent
   "py_to_jac",        # generates code — not read-only
   "jac_to_py",        # transpiles — not read-only
   "jac_to_js",        # transpiles — not read-only
   ```

3. **Add `PLAN_MODE_ALLOWED_TOOLS` allowlist for `bash` safe commands.** Rather than a blanket block, add a helper `isBashAllowedInPlanMode(cmd)` that permits a small set of read-only commands:
   ```
   ls, find, cat, head, tail, wc, grep, rg, git status, git diff, git log, git show, git branch (list only)
   ```
   Then change the `beforeToolCall` hook to check this for the `bash` tool specifically.

   **Alternative (simpler, nanocoder approach):** Block `bash` entirely. Agent has `glob`, `read`, `diagnostics`, `hover`, `definition`, `references`, `jac_check`, `jac_doctor`, and MCP read tools for exploration. If the agent needs to run a command, it should tell the user to switch modes.

   **Recommendation:** Start with the simpler approach (block `bash` entirely). We can add a safe-command allowlist later if needed.

4. **Update `PLAN_MODE_SYSTEM_APPENDIX`** with more detailed instructions:

   ```
   ## Plan mode (active)

   You are in **plan mode**: investigate the codebase and produce a clear, actionable implementation plan. You MUST NOT modify any files or execute commands.

   ### Available tools
   - **Exploration:** read, glob, diagnostics, hover, definition, references
   - **Jac tools:** jac_check, jac_doctor (read-only diagnostics only)
   - **MCP read tools:** search_docs, get_resource, list_examples, get_example, get_ast, understand_jac_and_jaseci, explain_error
   - **Visualization:** mermaid
   - **Web:** web_search, web_fetch (if configured)

   ### Blocked tools
   write, edit, bash, jac_run, jac_test, jac_format, jac_fix, jac_create, format_jac, execute_command, and all task mutation tools.

   ### Your output must follow this structure:

   1. **Current State** — What you found: relevant files, existing architecture, key archetypes (nodes, edges, walkers, abilities, components).
   2. **Proposed Changes** — What needs to happen and why. List each file to modify/create/delete.
   3. **Step-by-step Plan** — Numbered steps. For each step:
      - What to do
      - Which file(s)
      - Why (rationale)
      - Risk level: low / medium / high
      - How to verify
   4. **Dependencies** — Ordering, what blocks what, what can run in parallel.
   5. **Open Questions** — Anything unclear that needs user input.

   Output as markdown with checkboxed tasks (`- [ ] Step N: ...`).

   When the plan is complete, tell the user:
   "Plan complete. Switch to normal mode (Shift+Tab) to execute, or ask me to refine."
   ```

5. **Add `isPlanModeReadOnlyTool(toolName)` helper** that returns `true` for tools explicitly safe in plan mode. This gives us a positive allowlist rather than just a blocklist — useful for MCP tools that get added after boot.

**Updated `PLAN_MODE_BLOCKED_TOOLS`:**
```ts
export const PLAN_MODE_BLOCKED_TOOLS = new Set([
  // File mutation
  "write",
  "edit",
  // Shell execution — all blocked in plan mode
  "bash",
  // Jac write/run tools
  "jac_format",
  "jac_fix",
  "jac_create",
  "jac_run",
  "jac_test",
  // Jac MCP write tools
  "format_jac",
  "execute_command",
  "run_jac",
  // Transpile tools — generate code, not read-only
  "py_to_jac",
  "jac_to_py",
  "jac_to_js",
  // Task mutations — plan mode produces the plan itself
  "create_task",
  "update_task",
  "delete_task",
]);
```

---

### Task 2: Backend — MCP tool filtering in plan mode

**File:** `src/agent/dev-mode.ts`

**Changes:**

Add a function to check if an MCP tool (identified by not being in the core tool set) should be blocked in plan mode. The heuristic:

```ts
/** Tools that are known read-only — safe in plan mode. */
export const PLAN_MODE_READ_ONLY_MCP_TOOLS = new Set([
  "validate_jac",
  "check_syntax",
  "explain_error",
  "list_examples",
  "get_example",
  "search_docs",
  "get_resource",
  "get_ast",
  "understand_jac_and_jaseci",
  "list_commands",
  "get_command",
  "graph_visualize",    // read-only visualization
  "lint_jac",           // read-only analysis
]);

/** Whether an MCP tool is allowed in plan mode. */
export function isMcpToolAllowedInPlanMode(toolName: string): boolean {
  if (PLAN_MODE_BLOCKED_TOOLS.has(toolName)) return false;
  if (PLAN_MODE_READ_ONLY_MCP_TOOLS.has(toolName)) return true;
  // Unknown MCP tools are blocked in plan mode by default
  return false;
}
```

**File:** `src/session/agent-session.ts`

In the `beforeToolCall` hook, add MCP tool filtering:

```ts
// After the existing plan mode block check:
if (this._mode === "plan" && !isToolBlockedInPlanMode(toolName)) {
  // Also check if it's an MCP tool not in the read-only allowlist
  const coreToolNames = new Set(coreTools.map(t => t.name));
  if (!coreToolNames.has(toolName) && !isMcpToolAllowedInPlanMode(toolName)) {
    return {
      block: true,
      reason: planModeBlockReason(toolName),
    };
  }
}
```

---

### Task 3: Shell — `/plan` auto-enters plan mode

**File:** `templates/shell.cl.jac` (in the `submit_main` function)

**Changes:**

When `/plan <desc>` is invoked, automatically switch to plan mode before sending the prompt:

```python
if cmd.startswith("/plan") {
    plan_desc: str = cmd[5:].strip();
    if session and plan_desc {
        # Auto-enter plan mode
        if dev_mode != "plan" {
            if hasattr(session, "cycleMode") {
                # Cycle until we're in plan mode
                while dev_mode != "plan" {
                    dev_mode = session.cycleMode();
                }
            }
        }
        if hasattr(session, "runPlan") {
            session.runPlan(plan_desc);
        }
        # ... fallback ...
    }
}
```

Actually, the cleaner approach: add a `setMode` call to the adapter's `runPlan` action.

**File:** `src/core/adapter.ts`

In the `runPlan` action, add mode switching:

```ts
runPlan: async (prompt: string) => {
  const planDesc = prompt.trim();
  if (!planDesc) {
    throw new Error("Usage: /plan <task description>");
  }
  // Auto-enter plan mode if not already in it
  if (session.mode !== "plan") {
    session.setMode("plan");
    store.setMode("plan");
    uiContext.notify("Switched to plan mode", "info");
  }
  store.pushUserMessage(`/plan ${planDesc}`);
  const planMsg = [
    `Generate a detailed implementation plan for: ${planDesc}`,
    "",
    "Follow this structure:",
    // ... (existing structured prompt)
  ].join("\n");
  await session.sendUserMessage(planMsg);
},
```

---

### Task 4: Shell — Visual plan mode indicators

**File:** `templates/shell.cl.jac`

**Changes:**

1. **Plan mode banner.** When `dev_mode == "plan"`, show a persistent yellow banner above the prompt bar:

```python
def:pub PlanModeBanner() -> JsxElement {
    return (
        <Box borderStyle="round" borderColor="yellow" paddingX={1} marginTop={1}>
            <Text color="yellow" bold>{"📋 PLAN MODE"}</Text>
            <Text color="gray">{" — read-only exploration. Shift+Tab to switch to execute mode."}</Text>
        </Box>
    );
}
```

Render it conditionally in the main app layout, between the transcript and the prompt bar.

2. **Change prompt marker in plan mode.** Currently the prompt marker is always `">"`. In plan mode, use `"📋"` or `"PLAN>"`:

```python
# In the app() function, where prompt_marker is derived:
prompt_marker: str = "📋" if dev_mode == "plan" else ">";
```

3. **Enhanced status bar mode display.** The status bar already shows `plan` in yellow, but we should make it more prominent:

```python
# In StatusBar, when mode is "plan":
if mode == "plan" {
    # Already bold yellow — good. Add "READ-ONLY" suffix:
    <Text color="yellow" bold>{"plan (read-only)"}</Text>
}
```

---

### Task 5: Shell — Plan → Execute handoff

**File:** `templates/shell.cl.jac`

**Changes:**

When the user switches OUT of plan mode (via Shift+Tab), detect the transition and show a brief hint:

```python
# Track previous mode
has prev_dev_mode: str = "normal";

# In the useInput handler for Shift+Tab:
if key.tab and key.shift {
    prev_dev_mode = dev_mode;
    if session and hasattr(session, "cycleMode") {
        new_mode: str = session.cycleMode();
        # If transitioning FROM plan to execute mode, show hint
        if prev_dev_mode == "plan" and new_mode != "plan" {
            session.send("[execute] The plan above is ready. Switched to " + new_mode + " mode. Say 'execute the plan' to proceed, or refine first.");
        }
    }
}
```

Actually, sending a message automatically is too aggressive. Instead, just show a notification:

```python
if prev_dev_mode == "plan" and new_mode != "plan" {
    if hasattr(session, "notify") {
        session.notify("Switched to " + new_mode + " mode. Say 'execute the plan' to implement.", "info");
    }
}
```

---

### Task 6: Shell — Help panel and documentation

**File:** `templates/shell.cl.jac`

Update the HelpPanel to document plan mode more clearly:

```python
<Text color="white">{"/plan <desc>   enter plan mode + generate plan"}</Text>
<Text color="white">{"Shift+Tab     cycle mode: normal → auto-accept → yolo → plan"}</Text>
```

**File:** `AGENTS.md`

Add a plan mode section to the guidelines.

---

## File Change Summary

| File | Changes | Lines (est.) |
|------|---------|-------------|
| `src/agent/dev-mode.ts` | Expand `PLAN_MODE_BLOCKED_TOOLS`, add `PLAN_MODE_READ_ONLY_MCP_TOOLS`, `isMcpToolAllowedInPlanMode()`, improve `PLAN_MODE_SYSTEM_APPENDIX` | +60 lines |
| `src/session/agent-session.ts` | Add MCP tool filtering in `beforeToolCall` for plan mode | +10 lines |
| `src/core/adapter.ts` | Auto-enter plan mode in `runPlan` action | +5 lines |
| `templates/shell.cl.jac` | `PlanModeBanner` component, prompt marker change, mode transition notification, help panel updates | +30 lines |
| `AGENTS.md` | Plan mode documentation | +15 lines |

**Total estimated changes: ~120 lines across 5 files.**

---

## Implementation Order

1. **Task 1** — Backend tool blocking (foundation — everything else depends on this)
2. **Task 2** — MCP tool filtering (completes the safety story)
3. **Task 3** — `/plan` auto-enters plan mode (UX improvement)
4. **Task 4** — Visual indicators (user can see they're in plan mode)
5. **Task 5** — Plan → execute handoff (workflow completion)
6. **Task 6** — Documentation (keep docs in sync)

---

## Testing Plan

### Manual testing

1. Boot jackal, Shift+Tab to plan mode → verify yellow banner appears
2. Try `/plan add authentication to the API` → verify auto-enters plan mode, agent produces structured plan
3. While in plan mode, verify agent CANNOT call: `write`, `edit`, `bash`, `jac_run`, `create_task`
4. While in plan mode, verify agent CAN call: `read`, `glob`, `diagnostics`, `hover`, `jac_check`, `mermaid`
5. Shift+Tab out of plan mode → verify notification appears
6. Tell agent "execute the plan" → verify it proceeds in normal mode

### Automated testing

Add tests to `src/agent/dev-mode.ts`:
- `isToolBlockedInPlanMode` covers all new entries
- `isMcpToolAllowedInPlanMode` returns correct values
- `shouldAutoApprove` returns `false` for blocked tools in plan mode

---

## Open Questions

1. **Bash in plan mode:** Block entirely (nanocoder approach) or allow read-only commands? Recommendation: block entirely for now.
2. **Plan mode for subagents:** Should subagent tool calls also be filtered when the parent session is in plan mode? Currently the `agent` tool itself is allowed — the subagent gets its own tool set. We should probably pass the parent mode to subagent sessions.
3. **Plan persistence:** Should plans be saved as tasks or checkpointed automatically? Deferred — user can manually `/checkpoint create plan-foo`.
