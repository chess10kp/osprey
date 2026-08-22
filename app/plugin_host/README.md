# Jackal plugin host (D11 / D13 / D21)

Persistent Node **sidecar** for Pi-compatible JS extensions.

**Invariant:** JavaScript does **not** block the first frame. When extensions
are configured, Jac and Node start concurrently; the TUI accepts input
immediately; prompts may queue until the capability snapshot is ready.

Authoritative design: [`docs/PLUGIN-HOST-PLAN.md`](../../docs/PLUGIN-HOST-PLAN.md).

## Startup

```text
t=0
├─ Jac starts TUI/session (`session_boot`)
└─ Node host starts concurrently → load configured extensions

t≈first frame → TUI accepts input (`t_interactive`)
before first model request → `wait_extensions_ready` (or degraded)
```

Status example: `extensions: loading 3/5`. Smoke reports both
**time-to-interactive** and **time-to-extension-ready**.

## Declarations (native control plane)

`.jackal/extensions.json` or `"extensions"` in `.jackal`:

```json
{
  "extensions": [
    {
      "id": "stub.echo",
      "path": "./plugin_host/fixtures/stub_echo.mjs",
      "runtime": "node"
    }
  ]
}
```

`runtime: native` never starts Node. `activation: lazy` defers load until
first invoke (escape hatch). Default for `runtime: node` is parallel sidecar.

## Wire protocol

Newline-delimited JSON envelopes (same shape as `app/agent/protocol.jac` `Envelope`):

| Kind | Direction | Role |
|------|-----------|------|
| `host_hello` | host → Jac | protocol + node + caps + compat tier |
| `host_goodbye` | either | orderly shutdown |
| `host_status` | host → Jac | `starting` / `ready` / `degraded` / `dead` |
| `ext_load` | Jac → host | `{id, path, requires?}` |
| `ext_loaded` | host → Jac | `{id, tools:[…]}` or unsupported error |
| `ext_unload` | Jac → host | drop extension tools |
| `tool_invoke` | Jac → host | `{name, args}` (concurrent on host) |
| `tool_result` | host → Jac | `{ok, result\|error}` |
| `tool_update` | host → Jac | bounded progress (T1) |
| `tool_cancel` | Jac → host | abort by `correlation_id` |

## Compat honesty

Shipped surface: **Pi tool-extension compatibility** (`compat: T1` —
`tools` + `cancel` + `updates`). Commands, events, renderers, and session
hooks are stubs; declaring them in `requires` fails load loudly.

## Node packaging (P5)

| Source | How |
|--------|-----|
| `JACKAL_NODE_BIN` | Explicit override |
| `app/plugin_host/node/bin/node` | Pinned sidecar (preferred product path) |
| `app/plugin_host/.node-bin` | Symlink/wrapper |
| `node` on PATH | Contrib / early path |

```bash
./scripts/resolve-plugin-node.sh
```

Native Jackal stays small; total install may include a managed Node — that is
fine if Pi compatibility is the differentiator.

## Manual smoke

```bash
cd app
jac run ../scripts/plugin-host-smoke.jac
```

## Layout

- `host.mjs` — stdio JSONL host (concurrent tool dispatch)
- `pi_shim.mjs` — T0/T1 `registerTool` / activate surface
- `fixtures/stub_echo.mjs` — Jackal `handler(args)` spike shape
- `fixtures/pi_greet.mjs` — real Pi `execute(toolCallId, params)` shape
- `fixtures/pi_slow.mjs` — abortable slow tool (cancel tests)

## Pitfalls (learned building P1–P5)

- **Session owns the bridge** — smoke alone with `bridge=None` in turns is not the product path (`session_boot` / `plugins` in `agent/session.jac`).
- **Corr before write** — register the pending waiter, then write the envelope, or the async reader wins the race.
- **Inbox + pending** — correlated delivery still keeps envelopes in `inbox` for status/`drain_inbox`.
- **Jac globs** — mutable plugin state lives on `SessionPlugins` (field mutation); reassigning module `glob`s after a read in the same function breaks under Jac/Python.
- **`node` is reserved** in Jac — use `node_bin`.
- **Dual clocks** — always report interactive and extension-ready; early smoke ≈1 ms / ≈70 ms for two fixtures (daemon still deferred).

Full write-up: [`docs/PLUGIN-HOST-PLAN.md`](../../docs/PLUGIN-HOST-PLAN.md) §14.
