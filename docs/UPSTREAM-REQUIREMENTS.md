# Upstream Changes Needed for Phase 2 (byllm Integration)

## Overview

To replace `pi-agent-core` with `byllm` as Jackal's agent loop, we need two things:
1. **A TypeScript adapter** that wraps `byllm`'s Python `Model` to expose the same event interface Jackal's store/UI expects
2. **Upstream jac runtime support** for calling `byllm` from a Node.js process without spawning a subprocess

---

## 1. Jac Runtime: In-process Python calls from Node.js

**Current problem:** Jackal's Node.js process can only call Python code by spawning `python3` subprocess (the bridge). This is 20-50ms per call.

**What's needed:** The Jac runtime (embedded in the Ink TUI process via `jac tui`) should expose a way to call Python/Jac functions **in-process** from the JS side.

**Specific ask:** Add a JS-callable API to the jac runtime that lets TypeScript:
```ts
// Something like:
const runtime = getJacRuntime();  // already in-process via jac-ink
const model = runtime.eval("Model(model_name='...')");  // construct a byllm Model
const events = model.invoke({ messages: [...], tools: [...], stream: true });
// events is a generator/async-iterable of StreamEvent objects
```

**Why:** `byllm`'s `Model` is a Python object that uses `litellm` for HTTP calls. It can't be rewritten in JS. The Jac runtime already has a Python interpreter in-process (it's how `jac tui` works). We just need the JS↔Python bridge to not go through stdio.

**Alternative:** If in-process calling isn't feasible, a persistent Python worker (long-lived subprocess with JSON-RPC over a pipe) would also work — it avoids the per-call `spawnSync` overhead while keeping the process boundary. Something like:

```ts
// Start once at boot:
const worker = spawnPersistentPythonWorker("lib/jac/bridge/worker.py");
// Call many times without respawn:
const result = worker.call("byllm_invoke", { model: "...", messages: [...] });
```

This is simpler than in-process and would reduce per-call latency from 20-50ms to <5ms.

---

## 2. byllm Streaming Event → AgentEvent Mapping

**Current:** `pi-agent-core`'s `Agent` emits these events (defined in `types.d.ts`):

```ts
type AgentEvent =
  | { type: "agent_start" }
  | { type: "agent_end"; messages: AgentMessage[] }
  | { type: "turn_start" }
  | { type: "turn_end"; message: AgentMessage; toolResults: ToolResultMessage[] }
  | { type: "message_start"; message: AgentMessage }
  | { type: "message_update"; message: AgentMessage; assistantMessageEvent: AssistantMessageEvent }
  | { type: "message_end"; message: AgentMessage }
  | { type: "tool_execution_start"; toolCallId: string; toolName: string; args: any }
  | { type: "tool_execution_update"; toolCallId: string; toolName: string; args: any; partialResult: any }
  | { type: "tool_execution_end"; toolCallId: string; toolName: string; result: any; isError: boolean }
```

**byllm's StreamEvent** (from `types.jac`):

```jac
obj StreamEvent {
    has event_type: str,  # "thought" | "chunk" | "tool_call" | "tool_result" | "usage" | "steps_done"
        data: dict;
}
```

**Mapping needed in the adapter:**

| byllm StreamEvent | → AgentEvent |
|---|---|
| `event_type: "chunk"` with `data.content` | → `message_update` (streaming text) |
| `event_type: "thought"` with `data.content` | → `message_update` (reasoning tokens) |
| `event_type: "tool_call"` with `data.tool`, `data.args` | → `tool_execution_start` |
| `event_type: "tool_result"` with `data.result` | → `tool_execution_end` |
| `event_type: "usage"` with `data.total` | → custom event for context tracking |
| `event_type: "steps_done"` | → `agent_end` |

**What's needed from byllm:** The `StreamEvent.data` dict needs to carry enough info for the mapping:
- `tool_call` events need a stable `call_id` (currently they may not have one)
- `tool_result` events need to reference the `call_id` of the corresponding `tool_call`
- `usage` events should carry `prompt_tokens` and `completion_tokens` in a consistent structure

---

## 3. Tool Registration Protocol

**Current (`pi-agent-core`):**

```ts
interface AgentTool<TParameters extends TSchema = TSchema> extends Tool<TParameters> {
  label: string;
  handler: (params: Static<TParameters>, update: (partial: any) => void) => Promise<AgentToolResult>;
}
```

Tools are TypeScript functions with TypeBox schemas. Registered at boot via `Agent({ initialState: { tools: [...] } })`.

**byllm:**

```jac
obj Tool {
    has func: Callable,
        description: str = "",
        params_desc: dict[(str, str)] = None;
    def get_json_schema -> dict;
}
```

Tools are Python callables. Registered via the `def ask() by model(tools=[...])` pattern.

**What's needed:** Jackal's tools are in TypeScript (they use `fs`, `child_process`, `vscode-languageserver-protocol`, `pi-lsp-extension`). They can't be Python functions.

Two options:

### Option A: Dynamic tool bridge (recommended)
byllm should support registering "external" tools that aren't Python callables — just JSON schemas with a callback hook. When the LLM requests such a tool, byllm yields a `tool_call` event but doesn't try to execute it. The JS side handles execution and feeds the result back.

```python
# Something like:
external_tool = ExternalTool(
    name="read",
    description="Read a file",
    schema={"type": "object", "properties": {"path": {"type": "string"}}},
)
```

When the LLM calls `read`, byllm emits `tool_call` then pauses (or returns control). JS executes the tool and sends the result back. byllm continues the ReAct loop.

### Option B: Tool proxy in Python
Each TS tool gets a thin Python shim that calls back into JS. This is complex and fragile.

**Recommendation:** Option A. It matches the `pi-agent-core` pattern where the agent loop delegates tool execution to the host application.

---

## 4. Abort Support

**Current:** `pi-agent-core`'s `Agent.abort()` sets an `AbortSignal` that:
- Cancels the streaming HTTP request to the LLM
- Prevents pending tool calls from executing
- Emits `agent_end` with `stopReason: "aborted"`

**byllm:** The `on_iteration` callback can return `IterationAction.ABORT`, but this only fires between iterations, not mid-stream.

**What's needed from byllm:** A way to abort a streaming LLM call mid-response. This likely means exposing the underlying `litellm` stream's cancellation mechanism. Something like:

```python
model.abort()  # cancels the active streaming call
```

---

## 5. Conversation History / State Management

**Current:** `pi-agent-core` manages `AgentState.messages` (the full conversation history). Jackal reads/writes this directly:
- `this._agent.state.messages` — read for context usage, compaction, persistence
- `this._agent.state.messages = [...]` — write for compaction, session restore
- `this._agent.state.model = resolvedModel` — switch models mid-session

**byllm:** Uses a `conversation` list that's passed as a kwarg to each `ask()` call. The `history` list is mutated in-place.

**What's needed:** The adapter needs to be able to:
1. Read the current message history at any time (for context usage tracking)
2. Replace the message history (for compaction / session restore)
3. Switch models mid-session (for `/model` command)

These are straightforward if the adapter wraps a `Model` object and owns the `history` list. No upstream change needed — just adapter-level bookkeeping.

---

## 6. Auth: OAuth / API Key Resolution

**Current:** `@earendil-works/pi-ai` provides:
- `OAuthFlow` for browser-based auth (GitHub Copilot, Anthropic, etc.)
- `ApiKeyStore` for API keys stored in `~/.pi/agent/auth.json`
- `ModelRegistry` with provider-specific routing
- `getApiKey(provider)` callback in Agent constructor

**byllm:** Uses `litellm` which reads API keys from environment variables or config files. The `[plugins.byllm.model]` section in `jac.toml` configures `api_key` and `base_url`.

**What's needed:** Jackal's auth system (`src/auth/auth.ts`, 183 LOC) handles:
1. Listing available providers and models
2. OAuth browser flows for providers that require them
3. Storing/retrieving API keys
4. Selecting a model at runtime

For byllm, we'd need:
- A way to inject API keys into `litellm`'s config at runtime (not just from `jac.toml`)
- Or: Keep the existing `pi-ai` auth system and pass the resolved API key to byllm's Model constructor

**Recommendation:** Keep `pi-ai` auth as-is. The adapter resolves the API key via the existing `getApiKey(provider)` flow, then passes it to byllm's Model. byllm just needs to accept `api_key` as a constructor parameter (it may already support this via litellm's `api_key` param).

---

## Summary of Upstream Asks

| # | What | Where | Priority |
|---|------|-------|----------|
| 1 | **In-process Python calls** or persistent Python worker (not per-call spawn) | jac runtime / jac-ink | **Critical** — without this, byllm calls are still subprocess-spawned |
| 2 | **Stable `call_id` on byllm `tool_call` events** | byllm StreamEvent | High — needed to correlate tool_call ↔ tool_result |
| 3 | **External tool registration** (JSON schema + callback, not Python callable) | byllm Tool protocol | High — Jackal's tools are TS, not Python |
| 4 | **Mid-stream abort** for byllm Model | byllm Model | Medium — needed for Ctrl+C cancellation |
| 5 | **Accept `api_key` at runtime** in Model constructor | byllm Model | Low — may already work via litellm |

Items 1 and 3 are the hard dependencies. Items 2, 4, 5 can be worked around in the adapter layer.
