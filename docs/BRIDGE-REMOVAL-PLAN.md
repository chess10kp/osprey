# Plan: Keep Ink TUI, Gut the Bridge

**Goal:** Eliminate input latency by removing the Python stdio bridge from all hot paths. The Ink TUI stays; the `spawnSync` subprocess-per-call architecture goes away.

**Inspiration:** The jaseci `jac ai` agent (`reference/jaseci/jac/jaclang/cli/ai_agent.jac`) proves that the entire agent — LLM calls, tool execution, streaming, code intelligence — can run as in-process Jac code using `byllm`, with zero subprocess overhead.

---

## Problem Statement

Typing into Jackal's input field has visible latency because every keystroke triggers:

1. **`useCompletions` → `bridgeGetSuggestions` → `spawnSync` Python subprocess** (20–50ms blocking the Node event loop)
2. **`useTick()`** — global re-render subscription; any store event (streaming tokens, tool updates) triggers a full shell re-render while typing
3. **Monolithic `shell.cl.jac`** (~2100 lines) — every state change re-renders everything

The bridge has 209 ops across `jac-bridge.ts`. Most are called infrequently (config loading at boot, task CRUD on user action). But the architecture of spawning a Python subprocess for *every* call — even trivial ones — is fundamentally wrong for interactive use.

---

## Status

| Phase | Status | Commits |
|-------|--------|--------|
| **0** Debounce + local completions + targeted useTick | ✅ Done | `8f1e4a6` |
| **1** Remove bridge from mermaid + approval display | ✅ Done | `b9be410` |
| **2** Replace `pi-agent-core` with `byllm` | ⏳ Blocked — requires upstream jac-ink + jaclang changes |
| **3** Delete bridge entirely | ⏳ Blocked on Phase 2 |
| **4** Split shell component | ⏳ Blocked — requires jac-ink focus management support |

---

## Architecture After

```
User terminal
    │
    ▼
jackal.sh
    ├─ build dist/index.js (tsc)
    ├─ jac tui templates/shell.cl.jac → .jac/tui/
    ├─ postprocess (same as today)
    └─ node .jac/tui/runner.mjs
            │
            ▼
        createNextAgent(cwd)
            │
            ├─ JackalAgentSession (agent loop)
            │     │
            │     ├─ byllm Model (in-process via Jac runtime)
            │     │     └─ ReAct loop, streaming, tool calls
            │     │
            │     ├─ Tools: plain functions (read, write, edit, bash, etc.)
            │     │     └─ No bridge — direct Node fs/child_process
            │     │
            │     └─ CodeIntelligence (compiler-backed, via Jac runtime)
            │
            ├─ AgentStore (immutable snapshots, same as today)
            ├─ bridgeEvents() → store mutations
            └─ JackalUIContext (dialogs, notify)
```

**Key change:** The agent loop swaps from `pi-agent-core` Agent + `pi-ai` models to `byllm` Model. Tool definitions become plain TS functions (no bridge). The bridge directory (`lib/jac/bridge/toolchain_stdio.py`) is deleted entirely.

---

## Phase 0: Stop the Bleeding (Immediate Wins)

**Goal:** Fix the typing latency without any architectural changes. These are safe, targeted fixes.

### 0.1 Debounce `useCompletions`

**File:** `templates/jackal_agent_facade.mjs` → `useCompletions()`

Currently: `useEffect` fires on every `[input, cursorPosition]` change → spawns Python subprocess.

Fix: Add a 150ms debounce. Only compute suggestions after the user pauses typing.

```js
useEffect(() => {
  const timer = setTimeout(() => {
    // ... existing async computation
  }, 150);
  return () => clearTimeout(timer);
}, [input, cursorPosition]);
```

**Impact:** Eliminates the 20–50ms blocking on every keystroke. Suggestions appear after a brief pause instead of on every character.

### 0.2 Cache completions prefix matching in TS

**File:** `src/ui/completions.ts`

Currently: `getSuggestions()` delegates to `bridgeGetSuggestions()` → `spawnSync`.

Fix: Move the actual prefix-matching logic to TypeScript. The file list, slash commands, and model names are static for the session. Only the prefix filter changes on each keystroke — that's a pure string operation that doesn't need Python.

```ts
// Keep the bridge call for BOOT-TIME loading of the completion catalog
// (file list, commands, models) — cache it once.
// Then filter the cached catalog in pure TS on each keystroke.
export function getSuggestions(input: string, ctx: CompletionContext): Suggestion[] {
  return localPrefixFilter(cachedCatalog, input, cursorPosition);
}
```

**Impact:** Zero subprocess calls on the keystroke path. The bridge is only called once at boot to load the file/command/model catalog.

### 0.3 Split `useTick` into targeted subscriptions

**File:** `templates/jackal_agent_facade.mjs`

Currently: Every facade hook calls `useTick()`, which subscribes to a global `emit()` fired by store/auth/UI-context changes. This means streaming tokens (hundreds of events/sec) trigger re-renders of the input component.

Fix: Create separate hooks with targeted subscriptions:
- `useStoreTick()` — only store changes
- `useAuthTick()` — only auth changes
- `useUITick()` — only UI context changes

Input component only subscribes to auth + UI (for model picker state), not store streaming events.

**Impact:** Input re-renders only when auth state or dialogs change, not on every streaming token.

**Estimated effort:** 1–2 hours total for Phase 0. Can ship immediately.

---

## Phase 1: Remove Bridge from Hot Paths

**Goal:** Eliminate the bridge from all code paths that run during interactive use (typing, streaming, tool execution). The bridge stays for boot-time config loading only.

### 1.1 In-process completion engine

**Files:** `src/ui/completions.ts`, `lib/jac/ui/_completions_toolchain.py`

Replace `bridgeGetSuggestions` (spawnSync) with a local TS completion engine that:
1. Loads the completion catalog (file paths, commands, models) once at boot via `listProjectFiles` (async, one-time)
2. Filters the cached catalog in pure TS on each keystroke — no subprocess

The Python `completions_toolchain.py` becomes unnecessary. Delete it.

### 1.2 In-process dev-mode checks

**Files:** `src/agent/dev-mode.ts`, `lib/jac/agent/_dev_mode_toolchain.py`

Currently: `bridgeIsReadOnlyMode()`, `bridgeIsToolBlocked()`, `bridgeCycleMode()` → spawnSync on every tool call.

Fix: These are trivial boolean checks against a config object. Keep them as pure TS functions. The Python mirror is redundant — the TS copy already exists per AGENTS.md ("TS keeps local copy").

Delete: `lib/jac/agent/_dev_mode_toolchain.py` and its bridge ops.

### 1.3 In-process mermaid renderer

**Files:** `src/render/mermaid-render.ts`, `lib/jac/render/_mermaid_render_toolchain.py`

Currently: `bridgeRenderMermaid()` → spawnSync.

Fix: Move the mermaid rendering to pure TS (or call the npm `pi-mermaid` package directly — it's already a dependency). The Python version was a port of the TS version.

Delete: `lib/jac/render/_mermaid_render_toolchain.py` and its bridge ops.

### 1.4 In-process overlay formatting

**Files:** `src/ui/overlay-rows.ts`, `lib/jac/ui/_overlay_rows_toolchain.py`

Currently: Task overlay formatting calls `spawnSync`.

Fix: Keep as pure TS string formatting. Already a local copy per AGENTS.md.

Delete: `lib/jac/ui/_overlay_rows_toolchain.py` and its bridge ops.

### 1.5 In-process tool-summary formatting

**Files:** `src/core/tool-summary.ts`, `lib/jac/core/_tool_summary_toolchain.py`

Fix: Pure TS. Already a local copy.

Delete: `lib/jac/core/_tool_summary_toolchain.py`.

**Estimated effort:** 2–3 days.

---

## Phase 2: Replace `pi-agent-core` with `byllm`

**Goal:** Swap the agent loop from `pi-agent-core` Agent + `pi-ai` models to `byllm` Model. This is the largest change — it eliminates 16 TS files' dependency on the Pi SDK and makes the agent loop a Jac-native in-process operation.

### 2.1 Create a `byllm` adapter in TS

**New file:** `src/session/byllm-adapter.ts`

The `byllm` ReAct loop runs in-process via the Jac runtime (Python). We need a thin adapter that:

1. Receives user messages from the Ink TUI (via `actions.send()`)
2. Calls into the Jac runtime's `byllm` Model (in-process, no subprocess)
3. Streams `StreamEvent` objects back to `bridgeEvents()` for store updates
4. Exposes the same event interface (`agent_start`, `agent_end`, `tool_execution_start`, `tool_execution_end`, `streaming_text_chunk`) that the store/bridge currently expect

This adapter replaces `JackalAgentSession`'s use of `pi-agent-core` Agent.

### 2.2 Port tool definitions to Jac

**Reference:** `ai_agent.jac` shows the pattern — plain functions with `sem` annotations become byLLM tool definitions.

Current TS tools (`src/agent/tools.ts`) become Jac functions. Each tool is a plain function that can call Node APIs (fs, child_process) via the Jac runtime's `::py::` blocks, or stay as TS functions registered with the byllm adapter.

Two options:
- **Option A (simpler):** Keep tools in TS, register them with the byllm adapter via a JSON schema bridge (like `pi-agent-core` AgentTool, but calling byllm's tool protocol)
- **Option B (pure Jac):** Rewrite tools in Jac like `ai_agent.jac` — but this requires jac-ink to support `::py::` blocks in tool modules that import Node APIs

Recommend: **Option A** for Phase 2. Tools stay in TS (they use `fs`, `child_process`, `vscode-languageserver-protocol`). The byllm adapter registers them dynamically.

### 2.3 Wire streaming events

`byllm` emits `StreamEvent` objects: `thought`, `chunk`, `tool_call`, `tool_result`, `usage`, `steps_done`.

Map these to the existing store events:
- `chunk` → `streamingText` update
- `tool_call` → `tool_execution_start`
- `tool_result` → `tool_execution_end`
- `usage` → context usage update
- `steps_done` → `agent_end`

The `bridgeEvents()` function in `src/core/bridge.ts` already handles this mapping — it just needs to consume `StreamEvent` instead of `pi-agent-core` events.

### 2.4 Remove `pi-agent-core` and `pi-ai` dependencies

After the swap, delete:
- `@earendil-works/pi-agent-core` from `dependencies`
- `@earendil-works/pi-ai` from `dependencies`
- 16 TS files that depend on them (the "not portable" list from AGENTS.md)

Replace with `byllm` (via Jac runtime — already available since `jac` is installed).

**Estimated effort:** 5–7 days. This is the core of the rewrite.

---

## Phase 3: Delete the Bridge

**Goal:** Remove `lib/jac/bridge/toolchain_stdio.py` and all remaining bridge code.

After Phase 2, the only bridge calls remaining are boot-time config loading:
- `boot_batch` (project config, mode resolution)
- `session_boot_batch` (alwaysAllow, system prompt base, LSP config)
- `tasks_load/save` (file I/O for task persistence)
- `checkpoints_load/save` (file I/O for checkpoint persistence)
- `custom_commands_load/expand` (file I/O for slash commands)
- `sessions_*` (file I/O for session persistence)
- `auth_*` (auth file I/O)

### 3.1 Move config loading to in-process Jac calls

Replace `spawnSync` bridge calls with direct calls to the Python toolchain functions via the Jac runtime (in-process, no subprocess). The `.jac` wrapper modules in `lib/jac/*/` already exist — they just need to be called directly instead of through the stdio bridge.

### 3.2 Move file I/O to direct Node fs calls

Task persistence, checkpoint persistence, and session persistence are all JSON file read/write. These don't need Python at all. Rewrite as direct `fs.readFile`/`fs.writeFile` in the existing TS modules.

### 3.3 Delete `toolchain_stdio.py` and `jac-bridge.ts`

Once all consumers are migrated, delete:
- `lib/jac/bridge/toolchain_stdio.py` (the stdio dispatcher)
- `src/jac/jac-bridge.ts` (2220 lines of bridge wrapper functions)
- All `_*_toolchain.py` files whose logic moved to TS or in-process Jac

**Estimated effort:** 3–4 days.

---

## Phase 4: Split the Shell Component

**Goal:** Optimize the Ink rendering pipeline so input and streaming don't fight.

### 4.1 Extract InputBox from shell.cl.jac

Create `templates/components/inputbox.cl.jac` — isolated component with its own state:
- `input_text`, `input_cursor`, completions
- Only re-renders on input changes, not on store events
- Receives `on_submit`, `disabled` as props

### 4.2 Extract Transcript from shell.cl.jac

Create `templates/components/transcript.cl.jac` — isolated component:
- Subscribes to store transcript updates
- Only re-renders on transcript changes
- Uses Ink `Static` for finalized rows (no re-rendering old messages)

### 4.3 Shell becomes a thin layout

`shell.cl.jac` becomes a layout shell:
```
<BoxLayout>
  <StatusBar />
  <Transcript />
  <ToolDisplay />
  <InputBox />
</BoxLayout>
```

Each child manages its own re-render scope.

**Estimated effort:** 2–3 days.

---

## Summary

| Phase | What | Effort | Impact |
|-------|------|--------|--------|
| **0** | Debounce completions, cache prefix matching, split useTick | 1–2 hours | **Fixes typing latency immediately** |
| **1** | Remove bridge from hot paths (completions, dev-mode, mermaid, overlays) | 2–3 days | Eliminates all sync subprocess calls during interactive use |
| **2** | Replace `pi-agent-core` with `byllm` for agent loop | 5–7 days | Removes Pi SDK dependency; agent runs in-process as Jac code |
| **3** | Delete the bridge entirely | 3–4 days | Removes 2220 lines of bridge glue; all ops in-process |
| **4** | Split shell component | 2–3 days | Isolates input re-renders from streaming re-renders |

**Total estimated effort:** ~3 weeks

**Phase 0 can ship today** and should eliminate the user-facing typing latency. Phases 1–4 are the structural cleanup that prevents this class of problem from recurring.

---

## Risk Assessment

| Risk | Mitigation |
|------|------------|
| `byllm` API doesn't support all `pi-agent-core` features | Audit feature parity first: streaming, tool calling, abort, context window tracking. `ai_agent.jac` already proves ReAct + streaming + tools work. |
| jac-ink can't call Python runtime from Ink components | It doesn't need to — the agent loop runs outside Ink. Only the event bridge (TS) talks to Ink. Same as today. |
| Breaking session format | Phase 3 rewrites persistence in TS but keeps the same JSON format. Sessions are backward-compatible. |
| Performance regression in byllm vs pi-agent-core | Benchmark both before cutting over. byllm uses litellm (same HTTP client), so LLM call latency should be identical. The win is removing subprocess overhead. |

---

## What NOT to Do

1. **Don't rewrite tools in Jac yet** — keep them in TS, register with byllm adapter. Tool rewriting is a separate project.
2. **Don't touch jac-ink** — the TUI compile pipeline stays as-is. Only the runtime hooks (facade) change.
3. **Don't remove `.jac` wrapper files blindly** — remove only wrappers whose toolchains and bridge ops are already unused.
4. **Don't change the store/bridge event API** — too many consumers. Phase 2's byllm adapter emits the same events.

---

## What's Done (Phases 0–1 + bridge cleanup)

### Phase 0: Immediate latency fix (`8f1e4a6`)
- **`src/ui/completions.ts`**: Rewritten as pure TS. Slash commands, `@file` autocomplete, model/provider suggestions all run in-process. No bridge, no `spawnSync`. The Python `lib/jac/ui/_completions_toolchain.py` is now dead code.
- **`templates/jackal_agent_facade.mjs`**: Three targeted subscription hooks replace the global `useTick()`:
  - `useStoreTick()` — only store mutations (streaming, tools, phase)
  - `useAuthTick()` — only auth changes (login/logout/model)
  - `useUITick()` — only UI context (dialogs, notifications)
  - Input/completions only re-render on auth changes, not on every streaming token
- **`useCompletions`**: 120ms debounce + catalog caching. Completion catalog (file paths, commands, models) loaded once at boot, then filtered in pure JS.

### Phase 1: Remove bridge from remaining hot-path modules (`b9be410`)
- **`src/render/mermaid-render.ts`**: 360-line Python toolchain → pure TS flowchart/sequence/class/ER/state renderer. No bridge.
- **`src/ui/approval-display.ts`**: Tool approval preview generation → pure TS. No bridge.

### Bridge cleanup and runtime acceleration (`58193e8`, `4e0bd61`, `55588da`, `3259884`)
- Added **persistent Python worker** (`lib/jac/bridge/worker.py`, `src/jac/worker.ts`) and routed async bridge calls through it.
- Removed **all LSP support** from Jackal runtime (`src/jac/lsp-client.ts`, `src/jac/lsp-service.ts`, `src/jac/lsp-tools.ts`) and deleted LSP reference tree.
- Deleted dead Python toolchains and wrappers already replaced by TS (`completions`, `mermaid_render`, `approval_display`, `tool_summary`, `overlay_rows`).
- Removed dead LSP toolchains/wrappers (`_lsp_toolchain.py`, `_lsp_helpers_toolchain.py`, `lsp.jac`, `lsp_config.jac`).
- Switched adapter boot path to worker-backed async bridge ops for `boot_batch` and `session_boot_batch`.

---

## What's Blocked

### Phase 2: Replace `pi-agent-core` with `byllm`

**Blocker:** Requires upstream changes to jac-ink and jaclang that are outside Jackal's repo boundary (per AGENTS.md rule: "Do not modify jac-ink, jaclang, or jac-client").

**What needs to happen upstream:**
1. `byllm`'s `Model` class must be callable from the Jac runtime that's embedded in the Ink TUI process
2. The `Agent` class in `pi-agent-core` provides: streaming events, tool approval callbacks, abort, context window tracking — `byllm`'s `StreamEvent` provides most of these but the adapter wiring is non-trivial
3. Auth: `@earendil-works/pi-ai` handles OAuth flows with multiple providers. `byllm` uses `litellm` for provider routing. These are different auth models that need reconciliation.
4. 16 TS files (~5,100 LOC) depend on `pi-agent-core` types (`Agent`, `AgentTool`, `AgentMessage`). Rewriting these requires either:
   - A compatibility shim that maps `byllm` types to `AgentTool`/`AgentMessage` interfaces
   - Or rewriting every tool definition to use `byllm`'s tool protocol

**Files affected (16):**
```
src/session/agent-session.ts (1000 LOC — THE agent loop)
src/session/session.ts (368)
src/session/session-index.ts (304)
src/session/llm-compact.ts (50)
src/session/auto-compact.ts (144)
src/agent/tools.ts (703 — core tool definitions)
src/agent/task-tools.ts (235)
src/agent/web-tools.ts (302)
src/agent/agent-tool.ts (80)
src/agent/mcp-client.ts (132)
src/agent/tool-output-limit.ts (95)
src/workflow/context-usage.ts (79)
src/workflow/checkpoints.ts (343)
src/orchestration/subagents.ts (282)
src/orchestration/subagent-runner.ts (371)
src/auth/auth.ts (183)
```

**Recommendation:** This should be driven by the jaseci/jac team as part of the `jac ai` integration. Jackal's agent loop is architecturally equivalent to `ai_agent.jac` — the port path is clear but the scope is ~3 weeks of dedicated work.

### Phase 3: Delete bridge entirely

**Blocker:** Phase 2. The bridge still handles 209 ops, of which ~160+ are called from the agent session on the "cold" path (when the agent is running). These can't be removed until the agent loop no longer uses the bridge.

**What has already been cleaned up:**
- `lib/jac/ui/_completions_toolchain.py` — removed
- `lib/jac/render/_mermaid_render_toolchain.py` — removed
- `lib/jac/ui/_approval_display_toolchain.py` — removed
- `lib/jac/core/_tool_summary_toolchain.py` — removed
- `lib/jac/ui/_overlay_rows_toolchain.py` — removed
- `completions_get_suggestions`, `mermaid_render`, `mermaid_detect_type`, `approval_display_format` ops — removed from `toolchain_stdio.py`
- `lsp_*` ops and LSP config resolution bridge path — removed from `toolchain_stdio.py`

**What must stay until Phase 2:**
- All `store_*` ops (11) — used by `bridgeEvents()` in the reactive store layer
- All `session_*` ops (18) — used by session persistence
- All `auth_*` ops (12) — used by auth flows
- All `tasks_*` ops (13) — used by task CRUD
- All `checkpoint_*` ops — used by checkpoint CRUD
- All `dev_mode_*` ops (9) — used by tool filtering (TS has local copies but bridge is still called)
- All `subagent_*`, `chain_*`, `runner_*` ops — used by orchestration
- All `jac_*` CLI ops — used by jac check/format/test/run tools
- Boot batch ops, config ops, project ops

### Phase 4: Split shell component

**Blocker:** jac-ink's `useInput` hook is process-global (captures all keyboard events). Moving input handling to a sub-component requires focus management that jac-ink doesn't currently support.

**What could be done with jac-ink support:**
- `InputBox` component with its own `useInput` hook, only active when focused
- `Transcript` component that only re-renders on transcript changes
- `StatusBar` component that only re-renders on phase/mode changes

**Workaround (current):** The targeted `useTick` subscriptions from Phase 0 already isolate the input from streaming re-renders. The monolithic shell is ugly but no longer causes latency.
