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
3. **Don't remove the `.jac` wrapper files in `lib/jac/`** — they may be useful for in-process calls after the bridge is gone. Evaluate individually.
4. **Don't change the store/bridge event API** — too many consumers. Phase 2's byllm adapter emits the same events.
