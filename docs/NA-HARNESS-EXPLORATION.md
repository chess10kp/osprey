# Jackal all-Jac harness — exploration and decision record

**Exploration:** 2026-08-16 · **Decisions:** 2026-08-17
**Trigger:** jaclang removed the plugin system, so jac-ink / `jac tui` / `.cl.jac` are no longer a viable foundation.

> **Decision:** pivot to an all-Jac harness. The agent brain and product TUI are written in Jac and run in the server codespace where needed. Native is reserved for measured hot-path kernels in `app/core/`; it is not the placement target for the whole harness.

All toolchain claims below were verified against the installed Jac toolchain. The authoritative delivery sequence is in [`../ROADMAP.md`](../ROADMAP.md).

---

## 1. What changed in the Jac world

| Fact | Evidence |
|---|---|
| Plugin system **gone** | `jac tui` is no longer a valid command; jac-ink depended on the removed plugin entry point |
| Markerless placement is preferred here | Placement is inferred; file markers are not needed for the target architecture |
| Placement is inferred | JSX/npm imports → client; Python imports/graph archetypes/`::py::` → server; extern C → native; `[placement.pins]` can override |
| Native is available to anchor-free modules | `[build] default_codespace = "native"` and placement pins can select machine code for pure kernels |
| Jac can use Python and C ecosystems | Server Jac imports Python directly; native Jac can call C-ABI libraries |
| No first-class terminal client target | Jac client targets cover web/desktop/mobile, not terminal applications |

## 2. Verified spike results

```bash
$ jac nacompile tool.jac -o tool && ./tool Native
Hello, Native!

$ jac check --placements mixed.jac
hot.jac  [decided native]
mixed.jac
  <entry> (ModuleCode)     server

$ jac run mixed.jac
cwd: /tmp/na-spike
native hot call: 2
```

The repository now contains the first vertical slice:

- `app/main.jac` — term and JSONL adapters
- `app/agent/` — owned ReAct loop, injectable HTTP transport, tools, and prompt
- `app/core/edit.jac` — pinned native edit kernel spike
- `app/cordis/` — revertible-effect/reactive-coeffect composition spike
- `tui/` — temporary Ink JSONL client used to exercise the UI seam

## 3. Codespace policy

### Server brain

These concerns remain server-anchored because they need Python libraries, operating-system integration, blocking I/O, or dynamic runtime behavior:

- LLM HTTP/SSE transport
- sessions and persistence
- subprocess tools and `jac mcp`
- authentication and provider integration
- the TUI event loop and terminal lifecycle
- file discovery, configuration, and orchestration

### Native kernels

Only small, anchor-free, measured kernels belong in `app/core/`, for example:

- edit/diff algorithms
- ANSI-aware line comparison
- visible-width and wrapping calculations
- token estimation or parsing loops

A kernel is pinned native only when a benchmark shows a useful end-to-end improvement. Placement evidence is `jac check --placements`; placement alone is not a success metric.

### Explicitly rejected

- A mostly native agent loop
- Reimplementing TLS/HTTP/SSE through C FFI
- A single-binary requirement
- A C terminal framework as the primary UI strategy
- Native placement for code merely because it can compile there

C FFI remains available for a narrow platform quirk or a measured kernel. It is not the default UI foundation.

## 4. Product TUI decision

The line REPL is a **debug adapter only**. It is not an accepted N0–N2 product experience.

Jackal will build a small TUI framework directly in Jac, modeled on the architecture of `@earendil-works/pi-tui`. Pi's core renderer does not use Ink, React, ncurses, or a C rendering engine. Its useful design is:

```text
Component.render(width) -> lines
Component.handle_input(data)
Component.invalidate()

component tree
    -> width-bounded ANSI lines
    -> overlay/focus composition
    -> compare with previous frame
    -> emit one synchronized ANSI update
```

### Jac TUI modules

```text
app/ui/
├── terminal.jac       # raw mode, resize, stdin/stdout, restoration
├── input.jac          # escape sequences, paste, Kitty keyboard protocol
├── component.jac      # render / handle_input / invalidate interface
├── renderer.jac       # frame scheduling and differential ANSI output
├── width.jac          # ANSI and Unicode display width
├── overlay.jac        # positioning, visibility, focus stack
├── virtual_terminal.jac
└── components/
    ├── editor.jac
    ├── transcript.jac
    ├── markdown.jac
    ├── tool_line.jac
    └── select_list.jac
```

Server Jac can use Python standard-library interop (`termios`, `tty`, `select`, `signal`, `threading`, `queue`, and `sys.stdin/stdout`) without adding a third-party TUI framework. Native kernels may accelerate width, wrapping, or diff code later if profiling justifies them.

### Performance model

Performance comes from the renderer design, not from forcing the UI into native placement:

- cache component output until invalidated
- coalesce render requests to a frame budget (target: at most one frame per 16 ms)
- compare line arrays and update only the changed range
- emit one stdout write per frame
- use synchronized output (`CSI ? 2026 h/l`) where supported
- avoid reparsing completed markdown on each token
- test against a virtual terminal and PTY, not only string snapshots

### Renderer status

- **Custom Jac TUI:** product direction
- **JSONL Ink client in `tui/`:** temporary seam exerciser; not the long-term renderer
- **Line REPL:** debug/recovery adapter
- **Rich/Textual:** not the primary plan
- **Bubble Tea/Ratatui:** not selected; they add a second implementation language
- **Jac Desktop/web:** possible future adapter after terminal parity, not on the critical path

## 5. UI seam

The durable interface is a typed command/event model owned by the brain. JSONL is one transport adapter, not the interface itself.

Representative commands:

```text
session.open
turn.submit
turn.cancel
approval.respond
diff.respond
session.command
session.close
```

Representative events:

```text
session.ready / session.snapshot
command.result
turn.started
assistant.delta
tool.started / tool.finished
approval.requested / approval.resolved
diff.proposed / diff.resolved
turn.finished
protocol.error
```

Each envelope needs protocol version, request correlation, session/turn/tool identifiers, and monotonic sequence. The brain owns session, turn, tool, approval, and persistence truth. The renderer owns focus, selection, scroll position, layout, animation, and theme.

Adapters:

1. in-process Jac TUI adapter — product path
2. JSONL stdio adapter — compatibility, testing, and disposable clients
3. line adapter — diagnostics and recovery
4. in-memory adapter — deterministic UI tests

## 6. Runtime and concurrency

The current all-Jac loop is synchronous. A high-quality TUI must remain responsive while the model streams and while tools block.

The product path therefore requires:

- one UI event loop that owns terminal input and rendering
- agent turns executed outside that loop
- a bounded command/event queue
- cancellation that reaches the active model request and subprocess group
- terminal restoration on normal exit, exception, interrupt, and suspend/resume
- backpressure that may coalesce adjacent text deltas but never drops structural events

Python `threading`/`queue` through server Jac is acceptable. Native async is not required.

## 7. Migration policy

### Soft dual-track

The existing `src/` + `templates/` implementation remains runnable as parity reference until the all-Jac path reaches the cutover gate.

Binding rules:

1. New product features land in `app/` only.
2. Do not expand the TypeScript runtime or continue the May bridge/LSP migration.
3. Fix the legacy path only when required to keep it runnable during migration.
4. Do not delete `src/` or `templates/` before session data, safety behavior, and daily workflows have migrated.
5. The temporary Ink client may evolve only enough to exercise the typed UI seam; do not build a second product shell there.

### MCP

Use `jac mcp` as a subprocess from N2 onward. Revisit in-process MCP only after measuring startup or per-call overhead and showing it is material.

### Cordis

The Cordis core spike remains the owned composition model. Cordis prototyping may continue independently, but product integration must not block the TUI and daily-driver gates or freeze unstable interfaces prematurely. See [`CORDIS-DESIGN.md`](CORDIS-DESIGN.md).

## 8. Decisions — 2026-08-17

| Topic | Decision |
|---|---|
| Harness | All-Jac source under `app/` |
| Brain placement | Server-anchored |
| Native scope | Measured kernels only; no mostly-native harness |
| Product UI | Custom Jac TUI framework using direct ANSI and differential rendering |
| REPL | Debug/recovery adapter only |
| Existing Ink client | Temporary UI-seam exerciser |
| Existing TS runtime | Soft dual-track until all-Jac daily-driver parity |
| New feature work | `app/` only |
| MCP | `jac mcp` subprocess for N2+; measurement required to revisit |
| Single binary | Not a goal |
| C TUI library | Not required; narrow FFI remains an escape hatch |
| Desktop/web | Deferred optional adapter after terminal parity |

## 9. Superseded assumptions

The following Aug 16 assumptions are no longer active:

- “native-first” means most of the harness should compile native
- a line-oriented interface is acceptable through N2
- the product TUI should wait until a later Rich/Textual phase
- a mature TUI requires a C rendering library
- every anchor-free `core/*` module must be native regardless of benchmark value

The current roadmap and acceptance gates are maintained in [`../ROADMAP.md`](../ROADMAP.md).
