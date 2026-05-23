# jac-tui / jac-ink — Required Changes

**jac-tui** is the external repo at `~/repos/jac-tui`. **jac-ink** is the plugin inside it that adds `jac tui` — compile `.cl.jac` → Ink terminal app.

Jackal depends on jac-ink for UI compilation and the virtual `@jac/pi` hook module. Agent logic lives in **this repo** (`src/`).

## Agent workflow

| Who | Scope |
|-----|--------|
| **Human** | `~/repos/jac-tui/jac-ink`, jaclang/jac_client, `jac_pi_runtime_shim.mjs`, compile pipeline, `@jac/pi` wiring |
| **Jackal agents** | `src/`, `templates/shell.cl.jac`, `jackal.sh`, docs, `pi/skills/` |

**Rules for jackal agents:**
1. Do **not** modify jac-ink, jaclang, or jac_client.
2. Do **not** write or edit shim scripts or facades for the compile pipeline.
3. When something requires a framework fix, **stop and tell the human** — symptom, owning repo, recommended minimal change.

Canonical policy: [`AGENTS.md`](../AGENTS.md) § Runtime architecture notes.

---

## What jac-ink does for Jackal

```
shell.cl.jac  ──jac tui──▶  .jac/tui/module.mjs + runner.mjs
                                    │
                    @jac/pi hooks ◀─┘  (jac_pi_runtime_shim.mjs — emitted by jac-ink, human-owned)
                                    │
                    dist/index.js  (createNextAgent — jackal repo)
```

Adapter path is wired via `JACKAL_AGENT_DIST` / `JACKAL_AGENT_CWD` (set by `jackal.sh`). Formal `--adapter` support in jac-ink is a **human handoff** item (see below).

---

## Already done in jac-tui (cli.jac)

These landed in `jac-ink/jac_ink/plugin/cli.jac` (Jackal-specific patches):

| Change | Why |
|--------|-----|
| **Vite bypass** — use `ClientBundleBuilder` directly | Ink runs in Node; jac-client's Vite path targets browsers |
| **`@jac/pi` import detection + rewrite** | Virtual module → `./jac_pi_runtime_shim.mjs` |
| **`_ensure_pi_import()`** | Re-add `@jac/pi` import when compiler strips it but hooks are used |
| **`--with_pi` / `--no_pi` flags** | Control Pi dep injection |
| **Pinned `PI_DEFAULT_DEPS`** in emitted `package.json` | `pi-agent-core`, `pi-ai`, etc. |
| **`npm install --ignore-scripts`** | Avoid pi-tui native postinstall |
| **`_emit_jac_pi_runtime_shim()`** | Emits React hooks that boot an external adapter via `JACKAL_AGENT_DIST` |

See also: `jac-tui/docs/pi-interop-progress.md` (Phase 0 done, Phase 1 largely done).

---

## Still needed in jac-tui

**Agents working in the jackal repo must not implement these in jac-tui.** Document the requirement and hand off to the human, who maintains the jac-ink plugin.

### A. Compiler/toolchain (small, high priority)

| Item | Description | Owner |
|------|-------------|-------|
| **Formalize adapter injection** | e.g. `--adapter path/to/dist/index.js` or `jac.toml [tool.jac-ink] adapter = "..."` | jac-ink (human) |
| **Stop hardcoding Jackal paths** | Current shim tries repo-relative dist paths — should be env/config only | jac-ink |
| **Tests for Phase 1** | `test_pi_dependency_injection.jac`, bundle rewrite tests per `pi-interop-plan.md` §6 | jac-ink |
| **Document compile flags** | When to use `--no_pi`, how adapter env vars work | jac-ink docs |

### B. Generic Pi interop (large, per pi-interop-plan.md)

The full plan in `jac-tui/docs/pi-interop-plan.md` describes a **generic** Ink coding agent using **`pi-coding-agent`** (full Pi SDK + extensions). Phases 2–8 are mostly **not implemented**:

| Phase | Work | Relevant to Jackal? |
|-------|------|---------------------|
| **2** | Emit `jac_pi_adapter.mjs` — store, event bridge, hooks | Partially — Jackal already has this in `src/` |
| **3** | Editor + slash commands via Pi SDK | Partially — Jackal implements slash cmds in `shell.cl.jac` |
| **4** | `InkResourceLoader` + full `ExtensionUIContext` | **Yes** — port extension loading into Jackal runtime |
| **5** | Tool rendering, sessions, bash | **Yes** — but Jackal may wire tools in its own adapter instead |
| **6** | Ink login/model picker components in `jac_ink/pi/` | Partially done — Jackal built these in `shell.cl.jac` |
| **7** | Capability negotiation for unsupported pi-tui UI | Nice to have |
| **8** | Tests + user docs | jac-ink |

**Jackal approach:** Jackal uses **`pi-agent-core` only** (no `pi-coding-agent`). The pi-interop plan describes a generic jac-ink agent; Jackal is the product built on embedded-adapter mode:

1. **Embedded adapter mode (Jackal)** — external `createNextAgent()`, lightweight runtime — **this is the product**
2. **Full Pi SDK mode (generic jac-ink)** — optional future jac-ink mode, not a Jackal launch path

### C. Jackal-specific integration (short term)

Until jac-ink supports adapter injection cleanly (human applies plugin changes):

| Item | Where | Status |
|------|-------|--------|
| `JACKAL_AGENT_DIST` / `JACKAL_AGENT_CWD` env vars | jackal.sh + jac-ink shim | Done (shim owned by jac-ink — do not edit from jackal agents) |
| Example app using `@jac/pi` | jac-ink/examples | Missing — request from human |

---

## Changes NOT in jac-tui (jaclang / jac-client)

These affect compilation. **Human-owned** — agents document requirements only.

| Patch | Package | Purpose |
|-------|---------|---------|
| `_js_module_stem()` | `jac_client/.../compiler.impl.jac` | `.cl.jac` → correct `.js` stem |
| Skip `@jac/pi` in bundling | `jaclang/.../client_bundle.impl.jac` | Keep virtual import for jac-ink shim |

**Goal:** upstream into jaclang/jac-client so pip reinstall doesn't break Jackal.

---

## Recommended jac-tui work order (for human)

1. **Adapter injection flag** — clean `@jac/pi` → external adapter wiring
2. **Phase 1 tests** — lock in compile/rewrite behavior
3. **Dual-mode architecture** — embedded adapter (Jackal) vs optional generic jac-ink Pi SDK mode
4. **Upstream jaclang patches** — `.cl.jac` stem + `@jac/pi` bundling
5. **Optional:** Pi extension loading per `pi-interop-plan.md` Phase 4+

Jackal agents track these as handoff items in [FEATURES.md](./FEATURES.md) §6 — they do not implement them.

---

## Related docs

- [`jac-tui/docs/pi-interop-plan.md`](~/repos/jac-tui/docs/pi-interop-plan.md) — full generic Pi+Ink design
- [`jac-tui/docs/pi-interop-progress.md`](~/repos/jac-tui/docs/pi-interop-progress.md) — what's implemented
- [`jac-tui/jac-ink/README.md`](~/repos/jac-tui/jac-ink/README.md) — jac-ink user docs
- [`FEATURES.md`](./FEATURES.md) — Jackal feature checklist
- [`PLAN.md`](./PLAN.md) — Jackal implementation phases
- [`../../AGENTS.md`](../../AGENTS.md) — agent rules (framework → human)
