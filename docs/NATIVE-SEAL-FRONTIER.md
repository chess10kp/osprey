# Native seal frontier — zero server pins is reachable

**Date:** 2026-09-15
**Toolchain:** installed release `jac` (`~/.local/share/jac/bin/jac`, built 2026-09-13
23:34) — byte-identical to `jackal/vendor/jac/jac/zig-out/bin/jac`. Osprey's
`vendor/jac` source matches jackal's except one uncommitted jackal fix (see
§5).

---

## 1. What changed

The 2026-08-31 honest seal read (`app/jac.toml` comments) recorded 6 server
pins and a set of module-level seal walls. The 2026-09-13 compiler work in
`jackal/vendor/jac` removed the module-level walls:

| Vendor commit | Effect |
|---|---|
| `c1650ad45` | native callers reach pinned-server functions via a ctypes bridge (kills the E5093 boundary class) |
| `ad230d084` | py-image imports stay alive across sv-to-sv stubs and native dep lanes |
| `2b23814f4` | void lambdas with statement-call bodies return void |
| `3faf57172` / `ca40b902f` / `0fd37686c` | per-module native artifacts embedded at app seal; sealed native dispatch; demoted modules recorded as server in the placement map |

Module-level demotion is dead. What remains is **per-function Python seams
inside natively sealed modules** — "demoting X to Python-only" notes, not
module relocations.

## 2. Verification (2026-09-15)

Throwaway probe — pins were flipped, checked, and **restored**; no commit:

1. Flip all 6 server pins (`ui.gates`, `ui.focus`, `ui.input`, `ui.events`,
   `ui.inspect`, `ui.demo_live_shell`) to `native` in `app/jac.toml`.
2. `jac check .` → **56/56 modules pass, zero `E5092`, no module forced to
   the server codespace.** Only per-function demotion notes remain (~37
   functions).

With the original pins, `jac build` demotes the same function set plus
`constraints/oracle_driver.jac` (module-level: `dict.get`, for-loop iterable).
`oracle_driver` is a test-only JSONL driver — candidate for a pin, a rewrite,
or exclusion from the seal.

## 3. Remaining function-level seams (root causes)

| Module | Functions | Root cause |
|---|---|---|
| `ui/events` | `dispatch_event*`, `resolve_*`, `_get_focus_node`, `_set_focus`, `run_default_action`, `_default_move_focus`, `topmost_modal_overlay`, `trace_event_path` | `signature type 'UiSession'` — app-class signature erasure at the seal boundary |
| `ui/screen` | `build_main_shell`, `install_shell_contracts`, `shell_*` (8) | same `UiSession` signature wall |
| `ui/renderer` | `relayout`, `desired_cells`, `render_frame` + paint/damage cascade | `_run_layout` fails → cascade; per 08-31 notes the residue is erased app types (`LayoutState`, `CellBuffer`) crossing the boundary |
| `ui/terminal` | `ProcessTerminal.start/stop/poll_input`, `_ioctl_winsize`, `read_terminal_size` | FFI narrowing `i64→i32`, `tcgetattr`/`tcsetattr`/`ioctl` param 1, `struct.unpack` non-bytes buffer, `sys.stdin` attribute access, `any` unbox |
| `ui/transcript` | `_use_markdown` → `_message_lines` → height/projection cascade | `looks_like_markdown` un-lowerable; `for-loop iterable 'FuncCall'` |
| `ui/markup` | `_instantiate_tracked` → `lower_markup`, `print_generated` | dynamic archetype instantiation (`function 'archetype'`) — reflection-shaped |
| `ui/input_sequences` | `extract_sequences`, `decode_sequence`, `_is_complete_csi/osc`, `sequence_status` | `str.startswith` primitive, `PLUS on i64 vs i8*` (char+int layout), `i8* vs i64` comparison |
| `ui/input` | `InputNormalizer.feed` | `expression 'AtomUnit'` (plus the known runtime SIGSEGV risk — see §5) |
| `constraints/solver_journal` | `_journal_*` (13) | `attribute access 'kinds'` / `'id_tick'` — attribute access on dynamic state |
| `na_stdlib` `tty`/`termios` | `setraw`, `setcbreak`, `tcgetattr` | same FFI narrowing + subscript-access walls as `ui/terminal` |

Pattern read: three wall classes remain — (a) **app-class signature erasure**
across the seal boundary (`UiSession` family), (b) **FFI/primitive gaps**
(narrowing, unpack, `startswith`, char/int layouts), (c) **reflection-shaped
code** (archetype instantiation, dynamic attribute state).

## 4. Reference: how fx stays fully native

`jackal/reference/fx` is a terminal coding agent written in pure Zig (579
files, ~653k LOC, 7.8 MiB static binary, no runtime interpreter). Every area
where Osprey still seams to Python exists in fx as plain native code.

### 4.1 Terminal raw mode, winsize, resize (`src/ui/shell_runtime.zig`)

- `TerminalState.enableRawMode` (line ~98): save `tcgetattr`, then build raw
  mode **flag by flag** (`BRKINT/ICRNL/IXON` off, `CS8`, `ECHO/ICANON/ISIG`
  off), set `VMIN=1 / VTIME=0` explicitly, `tcsetattr(fd, .NOW, raw)`;
  `disableRawMode` restores the saved termios with `.FLUSH`. Comptime OS
  guards (`builtin.os.tag == .wasi`) instead of runtime fallbacks.
- Winsize: `std.posix.winsize` struct filled field-by-field + ioctl
  (`src/core/terminal/native_session.zig:4129`).
- Resize: a `Sigaction` handler installed via `installResizeSignal` —
  signal-safe, no polling loop.
- Input readiness: `std.posix.poll` over a fixed `pollfd` array
  (`shell_runtime.zig:263`), with explicit handling of POLLIN/POLLHUP
  revents.

Contrast: Osprey's `ui/terminal` fails on exactly these sites — silent
`i64→i32` narrowing at FFI calls, `tcgetattr`/`ioctl` param narrowing,
`struct.unpack` on a non-bytes buffer, `sys.stdin` attribute access. fx never
faces them because it calls the POSIX floor with explicitly typed fd ints and
byte buffers.

### 4.2 Stdin reads and escape parsing (`shell_runtime.zig`, `src/ui/input/escape_parser.zig`)

- Reads are **one byte at a time** into a fixed buffer, poll-gated
  (`self.read(buf[len .. len + 1])`, line ~191) — no append-concat growth.
- `escape_parser.zig` is a zero-allocation **fixed-stage state machine**:
  stage constants are `u8` (`sgr_mouse_stage = 7`, `legacy_x10_row_stage =
  12`, ...), CSI params accumulate with **saturating u16 arithmetic**
  (`appendCsiDigitSaturating`), and every sequence class carries a max-bytes
  discard budget (`sgr_mouse_max_bytes = 18`, `control_sequence_discard_max_bytes
  = 32`). Partial sequences survive read boundaries by construction — the
  parser holds a stage, not a string.

Contrast: Osprey's `ui/input_sequences` fails on `str.startswith`,
`PLUS on i64 vs i8*` (1-char string + int arithmetic), and `i8* vs i64`
comparisons — all symptoms of parsing bytes as strings. fx parses bytes as
integers.

### 4.3 Cell model and damage (`src/ui/render_engine/`)

- A **shadow buffer** holds the last committed frame as a flat array of cell
  structs (`shell.shadow`, `cellAt(x, y)`, cells carry style incl. fg and
  `hyperlink_id`) — `frame_builder.zig`.
- `terminal_diff.zig` (4,241 lines) splits the frame problem: `frame_cell_match`
  (cell equality), `frame_scroll_plan` (scroll vs repaint decision),
  `paint_plan` (batched ANSI emission), and a `FrameSink` write result that
  distinguishes `complete` / `terminal_partial_write` / `shadow_feed_failed`
  so a torn write resyncs instead of corrupting the shadow.
- Allocation is explicit and frame-scoped: allocator passed in
  (`buildAndFlushFrame(alloc, ...)`), surfaces initialized from the shadow,
  `defer deinit` — no hidden per-frame allocation.

Contrast: Osprey's renderer cascade starts at `_run_layout` (erased app-type
signatures at the boundary), not at the diff logic itself.

### 4.4 Markdown — no detect phase (`src/core/agent/assistant_presentation.zig`)

- fx has **no `looks_like_markdown`**. `MarkdownProcessor` is a streaming
  state machine fed bytes: explicit state fields (`in_code_block`,
  `code_fence_marker: ?u8`, `in_pipe_block`, `active_blockquote`, footnotes),
  a line buffer with inline CRLF normalization, `handleLine` on newline,
  `flush` at EOF (`push`/`flushWithCompletions`, line ~141–230). Code fences,
  pipe tables, blockquotes, OSC 8 links are decided line-by-line inside the
  processor.
- Line buffers are reused with `clearRetainingCapacity` — append churn stays
  flat across a long stream.

Contrast: Osprey's `ui/transcript` cascade starts at `looks_like_markdown`
(a two-phase detect-then-render shape that the native lowerer cannot express
through its string primitives). A single-pass streaming projector removes the
detect step entirely — and matches the ui/README "authoring pause" note that
`list[str]` is an interim paint host, not the forever DSL.

### 4.5 Event loop and dispatch (`src/ui/event_loop.zig`)

- Dispatch is a **fixed callback record** — `EventLoopCallbacks{ctx:
  *anyopaque, collect_facts: *const fn(...), handle_byte: *const fn(...),
  commit_frame: ...}` — a hand-rolled vtable, no dynamic tables, no string
  keyed lookup.
- Batching discipline: drain up to `max_input_reads_per_fact_collection = 32`
  reads / pending bytes, settle, then **one** `commit_frame` per wake-up.
  Input handling and frame commit are separated epochs.

Contrast: Osprey's `ui/events` demotes its whole dispatch family on
`signature type 'UiSession'` — the app-class signature does not survive the
seal boundary. fx's equivalent boundary type is an opaque context pointer plus
function pointers, which needs no type visibility across compilation units.

### 4.6 Reflection-free instantiation (`src/core/tooling/tool_dispatch.zig`)

- `Registry = mod_registry.ToolRegistry(Tool)` is generated over a
  **compile-time-known slice** of tool specs (`Registry{ .tools = &.{spec}
  }`); `dispatchToolCall` resolves against that static table; progress-label
  classification is a linear scan over static label strings.
- There is no dict-driven archetype construction anywhere — "instantiate a
  component from a description" is always a closed-world table known at
  compile time.

Contrast: Osprey's `ui/markup` fails at `function 'archetype'` — dynamic
archetype instantiation is reflection-shaped and cannot lower. The fx answer
is structural: make the instantiation universe closed and static.

### 4.7 Transferable patterns

1. **Bytes are integers, not 1-char strings.** Parse input as `u8`/int
   values; kill `startswith`/char+int arithmetic. Removes the
   `input_sequences` wall class and is the honest fix for the `ui.input`
   `buffer += data` SIGSEGV path (fixed-capacity buffer + explicit length).
2. **State machines over string methods.** Escape parsing as stage constants
   + saturating int params + discard budgets; survives partial reads without
   string concat.
3. **One streaming projector, no detect phase.** Replace
   `looks_like_markdown` + `_message_lines` with a byte-fed line processor
   with explicit block state.
4. **Opaque-context vtables at seam boundaries.** Where a native module must
   call into another unit, pass a context pointer + function-pointer record
   instead of requiring app-class signature visibility. This is the
   application-level analog of the ctypes bridge and a candidate shape for
   `UiSession`.
5. **Closed-world instantiation tables.** Replace dynamic archetype lookup
   with a static registry slice; anything not in the table is a compile-time
   error, not a runtime fallback.
6. **Fixed-layout journals.** `solver_journal`'s dynamic attribute access
   (`kinds`, `id_tick`) becomes struct-of-arrays / typed columns so attribute
   access lowers to offset loads.
7. **Frame-scoped explicit allocation.** Buffers owned per frame with
   `clearRetainingCapacity`-style reuse; no per-keystroke or per-cell
   allocation.
8. **Torn-write recovery.** Frame sinks report partial writes so shadow and
   terminal can resync (Osprey renderer should own the same state machine).

## 5. Caveats before committing the pin flip

- `jac check` green ≠ sealed artifact green. Osprey's rule stands: a pin flip
  is validated by `jac build` + running the sealed artifact. The 2026-08-31
  `ui.input` SIGSEGV was a clean-lowering/runtime-corruption case (RC +
  allocator, `self.buffer += data` path) and is still unprobed.
- The installed release binary (2026-09-13 23:34) **predates** jackal's
  uncommitted `func.impl.jac` fix (2026-09-14 16:41, keeps tests that cross a
  demoted seam in the Python test suite). If sealed test runs fail on shims
  calling unemitted symbols, that diff is the missing piece — sync it into
  `vendor/jac` before the validation run.

## 6. Port plan (candidate sequence)

1. Sync `func.impl.jac` test-seam fix into `vendor/jac`; rebuild the release
   payload.
2. `jac build` with flipped pins + sealed `jac test` sweep (`JAC_TEST_JOBS=0`,
   serial). Gate: every suite green on the sealed artifact.
3. Commit the pin flip (all six, one deliberate commit, walls annotated).
4. Then attack the remaining seams wall-class by wall-class, mapping each to
   its fx pattern (§4.7):
   - (b) FFI/primitive gaps first — compiler floors for `startswith`,
     narrowing casts, `struct.unpack` bytes view; on the Osprey side, port
     `input_sequences`/`input` to byte-integer state machines (pattern 1+2).
   - (a) signature erasure second — restructure `UiSession`-touching
     call chains toward opaque-context + callback-record shape (pattern 4)
     and/or give the seal boundary app-class layout visibility (compiler
     work, upstream-able).
   - (c) reflection-shaped code last — replace `looks_like_markdown` +
     archetype instantiation with a streaming projector and a closed-world
     instantiation table (patterns 3+5); convert `solver_journal` to typed
     columns (pattern 6).
5. `ui.input` runtime corruption: RC release audit of the concat/field-store
   path in `feed` before trusting a native seal of that module.
