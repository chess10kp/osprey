# P12: Interactive ctx.ui round-trip — design plan (MintXenon × gpt-5.6-sol, 2026-08-22)

Closes compat-audit gap R.5 #1: extension `ui.select/confirm/input` currently
resolve immediately (4/5 audited extensions hit this). Scope is deliberately
minimal: those three methods only; `ui.editor()`/`ui.custom()` reject with a
clear unsupported error instead of faking values.

## 0. Findings that make this harder than it looks (verified in tree)

1. `host.mjs` awaits `cmd_invoke`/`hook_fire` inline in the stdin loop — a
   handler awaiting UI prevents the host from reading the reply that would
   unblock it. The stdin loop must interleave.
2. `app/tui.jac::_run_slash` runs `run_command()` synchronously on the TUI
   main thread → the modal could never render or receive keys. Extension
   commands must move to a worker.
3. `plugin_bridge.jac::_wait_corr` has a fixed 10s one-shot budget — real
   user interaction doesn't fit; needs lease pausing.
4. Pending correlation map is not kind-aware (`tool_update` already shares
   its parent correlation with `tool_result`) — kind-aware waiter matching
   must land BEFORE UI interleaving tests.
5. The live approval implementation is a single `app.appr_event`, not the
   tested `ApprovalQueue`; reuse the worker-blocking pattern, not the code.
6. TUI has two identical `__approve__` branches and `_approval_lines()`
   shows a hardcoded tool name — fold into the generic modal controller.
7. Tool `execute()` receives `{cwd}` only — no `ui`; concurrent tool_invoke
   UI requests need that context fixed too.
8. `cancel_active_turn()` installs after early hooks; react_loop doesn't
   re-check cancel right after `tool_call_gate()`.

## A. Wire protocol (additive, protocol stays v1)

New kinds in `protocol.jac::PLUGIN_KINDS`:

**`ui_request`** (Node → Jac), child correlation id (`ui-N`), NEVER the
parent's:
```json
{"kind":"ui_request","correlation_id":"ui-17","payload":{
  "parent_correlation_id":"corr-9","parent_kind":"hook_fire",
  "extension_id":"pi.example","method":"select",
  "title":"...","options":[...],"timeout_ms":30000}}
```
method payloads: select{title,options}, confirm{title,message},
input{title,placeholder}; all carry effective timeout_ms (capped by Jackal).

**`ui_response`** (Jac → Node):
`{"status":"ok","value":...}` or `{"status":"cancelled","reason":"escape"}`.

| method | ok value | cancel/timeout |
|---|---|---|
| select | chosen string | undefined |
| confirm | bool | false |
| input | string incl. "" | undefined |

Empty submitted input must stay distinguishable from Esc.

**`ui_cancel`** (Node → Jac): when AbortSignal/timeout/shutdown resolves the
Promise first. First terminal action wins; late responses ignored.

Correlation rules: parent corr reserved for cmd_result/hook_done/tool_result;
child corr used for exactly one interaction; Jac replies may be out of order
by child id; response value validated against original options.

## B. Node side

1. **UI Promise broker in `host.mjs`**: pendingUi Map, parent→children index,
   timeout/signal cleanup, requestUi/resolveUi/cancelUiForParent/cancelAllUi.
2. **Non-blocking stdin dispatch preserving serial semantics**: ui_response/
   tool_cancel/host_goodbye = immediate fast paths; tool_invoke concurrent as
   today; cmd_invoke/hook_fire/load/unload/transforms append to a serial
   Promise chain NOT awaited by the stdin iterator. host_goodbye bypasses a
   blocked chain, cancels all UI, aborts tools.
3. **makeUi() becomes bridge-backed** in `pi_shim.mjs`: select/confirm/input
   via the broker (opts.timeout, opts.signal); editor/custom throw explicit
   unsupported; one-arg confirm tolerated. Shared handler context constructor
   `{ui, hasUI, cwd, signal}` — also given to tool execute(). Parent handler
   completion cancels its outstanding children.

## C. Jac side

New module **`agent/interactions.jac`** hiding threading behind:
enqueue / poll-oldest / resolve-by-child-id / cancel-by-child-or-parent /
cancel-all-on-abort-dispose / expire-by-deadline / has-open(parent).
Internal lock around FIFO records + child-id map + parent open-counts.
The reader thread only decodes/validates/enqueues — never waits on a modal.

**plugin_bridge.jac**: interaction queue + availability flag on PluginBridge;
thread-safe `_alloc_corr`/waiter registration/dispatch; parent waiters record
expected terminal kind; `_dispatch_inbound()` routes ui_request/ui_cancel;
expose poll_ui_request/respond_ui/cancel_ui/cancel_all_ui. Don't duplicate
ui_request into the unbounded diagnostic inbox.

**Timeout leases**: keep 10s non-UI handler budget but PAUSE it while
correlated UI is pending; honor smaller Pi opts.timeout; cumulative 600s max
UI lease per parent; resume remaining budget after children close; reader EOF
or host death wakes waiters immediately.

**Fake-host parity**: fake_host.jac FakeUi uses the same interaction
interface; tests block handlers on worker threads and resolve from the test
thread — proving real blocking/correlation, not scripted values.

## D. Session integration

- `session_boot()` gains interactive_ui availability: tui.jac passes True;
  line/JSON frontends False this slice.
- Install TurnCancel BEFORE input_gate/early hooks (moves earlier than today).
- cancel_active_turn also cancels that turn's bridge interactions; dispose
  cancels all before session_shutdown.
- react_loop re-checks cancellation immediately after tool_call_gate()
  (fixes abort-during-dialog tool execution race).
- Esc on an extension modal cancels only that dialog; turn abort cancels all.

## E. TUI

Reuse ApprovalOverlay + shell_open/close_approval; generalize into one
foreground modal record {source, correlation_id, method, title/message,
options, selected_index, input_draft, deadline}. Mainloop tick: drain new
interactions → open oldest if none active → check cancellation → render/route
keys → close+reply → next. One visible modal; queue is FIFO, never stacked.

Keys: select ↑/↓+Enter, Esc cancels; confirm y/Enter, n/Esc; input text+
paste+Backspace+Enter, Esc cancels. Cap option/title lengths and queue depth;
overflow cancelled explicitly, never silently dropped.

**Extension slash commands move off the TUI thread** (mandatory — otherwise
`/cmd → await ui.select()` deadlocks before the first modal frame): built-ins
stay synchronous; run_command for extensions runs on a daemon worker,
completion returns through the event queue; _tick_stream generalizes into a
worker-event tick that also runs while ready/modal-open.

## F. Capability honesty

`interactive_ui` added to HOST_CAPS + FAKE_HOST_CAPS; COMPAT_TIER stays
"T2-partial". Composite capability: Node supports round trips AND the current
frontend installed an adapter — requires:["interactive_ui"] fails loud in
line/JSON mode; ctx.hasUI set accurately from client availability passed in
ext_load. Document: interactive_ui means select/confirm/input ONLY.

## G. Test plan

Fake-host: command blocks until select answered; confirm yes/no/Esc mapping;
empty-input vs cancelled; hook verdict incorporates answer; two concurrent
handlers → distinct child ids, FIFO prompts; out-of-order replies reach the
right handler; timeout/late-reply idempotent; abort/dispose drains all;
parent≠child correlations; requires-gating by frontend availability.

Node fixture `fixtures/pi_interactive.mjs`: select/confirm/input commands +
verdict-dependent hook + UI-using tool (concurrent invoke) + editor/custom
probes failing loudly. Envelope order asserted:
cmd_invoke → ui_request(child) → ui_response(child) → cmd_result.

TUI virtual-terminal tests: selection movement/submit, confirm reject/Esc,
unicode/paste/backspace/empty submit, focus restore, timeout closes modal,
approval vs extension modal don't overwrite each other, queued second opens.

PTY smoke (stdlib only): temp .jackal/extensions.json requiring
interactive_ui; first frame before extension readiness; select choose;
confirm Esc-cancel; input type+submit; results reach transcript; clean exit.

## H. Top risks

- Late ui_response after Node timeout → ignored, never "degraded".
- Deadline runs from request creation (bounded even while queued behind
  another modal).
- Parent returning with child pending → cancel child immediately.
- Handler ignoring its resolved Promise can still hang → serial chain kept,
  surface degraded status, never block stdin reader.
- session_start warm-flow UI requests queue but never block first frame.
- Kind-unaware correlation bug lands FIRST as a prerequisite commit.

## Suggested slice order

1. Prereq: kind-aware correlation matching (+ cancel-after-gate fix).
2. interactions.jac + bridge queue + wire kinds + fake-host parity (tests
   prove real blocking without Node).
3. Node broker + non-blocking stdin + bridge-backed makeUi + fixture.
4. TUI: worker-ized extension commands + generic modal controller + PTY smoke.
5. Caps gating polish + docs.

---

## Status (2026-08-23, MintXenon) — slices 1–5 landed

| Slice | Commit | Contents |
|-------|--------|----------|
| 1 | `889e20b` | kind-aware correlation waiters + cancel-after-gate race fix |
| 2 | `5c4508b` | interactions.jac queue (peek-poll/expiry/cancel), ui_request/ui_response/ui_cancel kinds, bridge wrappers + dispatch routing |
| 3 | `c3a3405` | Node UI promise broker (settle-once, late-reply ignored), non-blocking stdin serial chain, bridge-backed ctx.ui with Pi result mapping, fixture pi_interactive.mjs |
| 4 | `272c998` | TUI modal controller (shared overlay node, approval wins), workerized extension commands, _wait_corr UI lease (600s cumulative cap), session_boot(interactive_ui=) plumbing |
| 5 | this commit | composite cap gate: requires:["interactive_ui"] + no frontend adapter → loud ext_load failure |

**Deviations from plan:**
- interactive_ui advertises select/confirm/input ONLY; editor/custom throw
  explicit unsupported errors (documented, per compat honesty).
- tool execute() still receives no ui ctx (plan finding #7) — deferred;
  fixture ui_tool is a registration probe only.
- Fake-host parity tests (slice 2 scope) and PTY smoke (slice 4 scope) are
  written into the plan but NOT yet landed as executable tests — the shared
  jac runtime cache on the dev box made test runs infeasible during this
  push; code was verified by subagent review instead. First quiet window
  should run: agent/interactions.test.jac, agent/plugin_bridge.test.jac
  (--test_name interaction), then a manual TUI smoke against
  fixtures/pi_interactive.mjs.
