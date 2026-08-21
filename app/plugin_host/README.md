# Jackal plugin host (D11 / D13)

Lazily spawned Node process that runs Pi-compatible JS extensions. **Not** on Jackal’s default startup path — the Jac brain starts this only when an extension is loaded.

## Wire protocol

Newline-delimited JSON envelopes (same shape as `app/agent/protocol.jac` `Envelope`):

| Kind | Direction | Role |
|------|-----------|------|
| `host_hello` | host → Jac | protocol + node version + caps |
| `host_goodbye` | either | orderly shutdown |
| `host_status` | host → Jac | `ready` / `degraded` / `dead` |
| `ext_load` | Jac → host | `{id, path}` module to activate |
| `ext_loaded` | host → Jac | `{id, tools:[…]}` schemas |
| `ext_unload` | Jac → host | drop extension tools |
| `tool_invoke` | Jac → host | `{name, args}` |
| `tool_result` | host → Jac | `{ok, result\|error}` |
| `tool_cancel` | Jac → host | cancel by `correlation_id` |

## Manual smoke

```bash
cd app
# From Jac (preferred):
jac run ../scripts/plugin-host-smoke.jac

# Or pipe a single load by hand:
printf '%s\n' '{"kind":"ext_load","correlation_id":"c1","payload":{"id":"stub.echo","path":"'"$(pwd)"'/plugin_host/fixtures/stub_echo.mjs"}}' \
  | node plugin_host/host.mjs
```

## Layout

- `host.mjs` — stdio JSONL loop
- `pi_shim.mjs` — `registerTool` / activate surface
- `fixtures/stub_echo.mjs` — one echo tool for tests
