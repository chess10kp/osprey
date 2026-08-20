# pi-tui → Jac via js2jac: zero-hole milestone and diagnostic census

**Source:** `~/repos/notes/reference/pi/packages/tui` (`@earendil-works/pi-tui`, 28 non-test TypeScript modules).

**Converter:** the Jackal-local js2jac snapshot under `tui/js2jac/`, driven by `tui/scripts/holeconvert.mjs`.

**Census date/compiler:** 2026-08-18, `jac 0.36.0`.

## Current milestone

The **zero-hole conversion milestone is complete**. All 28 source modules emit Jac, and none of the emitted modules contains a `JS2JAC-HOLE` marker. This is a converter coverage milestone, not a compilation or runtime milestone.

| Gate | Current result | Meaning |
|------|---------------:|---------|
| Emitted | **28 / 28** | The converter produced a `.jac` file for every source module. |
| Zero-hole emitted | **28 / 28** | No emitted file contains a converter hole marker. |
| Independently checks | **34 / 34** | `jac check <module>` reports zero errors for every file in `pi_jac_floor/src` (28 ported modules + 6 Jac-native adapters). |
| Runtime verified | **Whole library** | Every module executes under `jac run` via **22 green smokes**, including shell integration (`smoke_shell.jac`) and Ink parity fixtures (`smoke_parity_wrapping.jac`, `smoke_parity_markdown.jac`). |

## Runtime-completion milestone (2026-08-19)

The **whole converted library now executes under the Jac runtime.** All 34 files
in `pi_jac_floor/src` (28 ported modules + 6 Jac-native adapter modules) `jac
check` clean individually — including `components/editor.jac` — and **22
`smoke_*.jac` files all pass `jac run`** with no regressions.

`editor.jac` (the last module, ~1570 lines) was cleared of its final 28 `jac
check` errors and driven end-to-end by `smoke_editor.jac`, which instantiates the
full `Editor` with stub `tui`/`theme` and walks set/get text, cursor motion,
insertion, undo, a full `render()` pass, and the large-paste → `[paste #N]`
marker collapse + delete-renumber path. Porting the residual JS-isms surfaced
several new check-silent runtime crashers (below): `EditorState`/`RegExp` shim
objs replaced dict-state + JS `RegExp`; the custom `__init__` had to explicitly
seed all ~30 `has` fields (Jac skips has-defaults when `__init__` is custom);
`self.segment()` was made to return a uniform `list[Seg]` (marker branch built a
dict before); float→int coercions were added at every list index/slice; and
`killRing.append`/`len(killRing)` were ported to `.push()`/`.length()` once
`handleInput` exercised the kill/yank path.

The porting method throughout was **runtime-first**: static `jac check` is not
the gate (it does not block `jac run`, and this `jac 0.36.0` checker is both
laxer in some places — accepting JS globals — and stricter in others than the
runtime). Each module was *imported and exercised* by a smoke; the real bugs are
the check-passing-but-runtime-crashing ones a smoke surfaces.

**Six Jac-native runtime adapters** reproduce the Node/JS surface the conversion
left intact, each on the Python stdlib, matching the JS-shaped API the converted
consumers call:
- `unicode_support.jac` — `Intl.Segmenter`, east-asian width, `\p{...}`/`\X`
  predicates, on `unicodedata`.
- `input_support.jac` — `EventEmitter`, cooperative timers, `AbortController`/
  `AbortSignal`, a synchronous `Promise` shim, `is_buffer`.
- `terminal_support.jac` — `process`, interval/timeout timer queue, a `Number` shim.
- `image_support.jac` — `Buffer` base64/byte reads, `readUInt*`, `Math.random`,
  guarded tmux probe, on `base64`/`subprocess`.
- `markdown_support.jac` — a from-scratch Jac reimplementation of the slice of
  the `marked` npm lexer the component needs (block + inline lexer, `Tokenizer`
  override hook).
- `autocomplete_support.jac` — `readdirSync`/`statSync`/path helpers, and a
  synchronous `run_fd` subprocess wrapper (async/Promise + `child_process.spawn`
  collapsed to guarded synchronous `subprocess.run`).

**Recurring runtime-crash bug classes** fixed across the modules (all pass `jac
check` yet crash under `jac run`):
- Doubled escape literals — emitted `\\x1b` (backslash-x-1-b) where a real ESC
  byte `\x1b` was meant — broke every terminal escape/redraw sequence. Found in
  `terminal_image`, `image`, `tui`, `input`, and others.
- JS object dot-access on Jac dicts (`obj.key` → `AttributeError`) — the single
  most common crasher; fixed to `obj["key"]`/`obj.get("key")` throughout.
- JS collection APIs left intact: `.length`, `.push`, `.unshift`, `.find`,
  `.filter`, `.map`, `.reduce`, `.has`, `set.delete`, `.size`, `Object.entries`,
  `array.length = 0` → Jac/Python equivalents.
- Zero-arg `super()`/`super().__init__()` cannot be lowered → call
  `Base.__init__(self, ...)` / seed inherited fields directly.
- A custom `__init__` suppresses auto-application of `has` field defaults →
  every declared field must be seeded explicitly (missing ones → runtime
  `AttributeError`).
- Non-default `has`/param after a defaulted one → dataclass field-order error.
- Inline lambda passed directly as a call argument fails native lowering at
  runtime (`cannot access local variable '__jac_lambda_N'`) though `jac check`
  is silent → bind the lambda to a name first.
- `?? default`-lowered IIFE lambdas reference a mangled private name undefined at
  call time → `x if x is not None else default`.
- Float used as a string/list index (Python raises) → `int(...)` / retype the
  index local to `int`.

**Two genuine logic/robustness bugs** surfaced by runtime execution, not visible
to `jac check`:
- `tui.expandChangedRangeForKittyImages` — a `continue` before the loop
  increment → infinite loop on any line with zero kitty-image ids.
- `keys.matchesKittySequence` — `KeyError` on `baseLayoutKey` for arrow/func/
  home-end kitty sequences that never populate that key (→ `.get`).

**22 green smokes:** `pure`, `render`, `input` (StdinBuffer), `keys`,
`terminal`, `word_nav`, `editor_wordmotion`, `editor_state`, `editor`,
`editor_input`, `pipeline`, `terminal_image`,
`components` (loader/cancellable/truncated/spacer/colors/select), `image`,
`markdown`, `tui`, `autocomplete`, `input_component`, `settings_list`,
`shell` (Terminal → StdinBuffer → TUI → Input + cooperative render loop),
`parity_wrapping`, `parity_markdown` (Ink fixture parity).

Run all: `cd tui/pi_jac_floor && for f in smoke_*.jac; do jac run $f; done`

`smoke_editor_input.jac` drives `Editor.handleInput()` — keybindings, kill/yank,
undo, newline, and bracketed-paste framing — surfacing `killRing.append` →
`.push()` and `len(killRing)` → `.length()` bugs invisible to `jac check`.
`smoke_pipeline.jac` chains `StdinBuffer` → `Editor.handleInput` for the full
bytes-to-editing-surface path.

## Integration progress (2026-08-19)

First converted-code execution under the Jac runtime. The generated tree is now
a runnable Jac project: `tui/pi_jac_floor/jac.toml` plus two entry smokes.

**Jac-native runtime adapters added** — `src/unicode_support.jac`. The
conversion left JS/browser globals that static `jac check` accepts but that
crash at runtime: `Intl.Segmenter` (grapheme/word segmentation), the
`get-east-asian-width` interop, and four `\p{...}` Unicode-property regexes
(stdlib `re` has no `\p`/`\X`, and the frozen `jac` binary cannot pip-install
`regex`). All are reimplemented on stdlib `unicodedata`, reproducing the
JS-shaped API the converted consumers call (`.segment()`, `.test()`):
grapheme segmenter (UAX-29-lite: marks, ZWJ, variation selectors, regional
indicators), east-asian width, and `isZeroWidth`/`stripLeadingNonPrinting`/
`isRgiEmoji` predicates. `src/utils.jac` is rewired onto these and still checks
clean.

**Converter/port bugs fixed to reach runtime** (emitted-file fixes; converter is
the upstream owner):
- `utils.splitIntoTokensWithAnsi`: a `flushCurrent` lambda reassigned captured
  locals — impossible in a Python closure without `nonlocal` (crashed with
  `UnboundLocalError`). Inlined at both call sites.
- `components/box.Box.__init__`: a custom `__init__` suppresses Jac's
  auto-application of `has` field defaults, so `children`/`cache` were never
  initialized (`AttributeError`). Now set explicitly.

**Input adapter added** — `src/input_support.jac`. The converted stdin path
kept Node globals: the `events` `EventEmitter` base, `setTimeout`/`clearTimeout`,
`Buffer`, and `String.fromCharCode`. This module reproduces that surface
in-process: an `EventEmitter` (on/emit/removeAllListeners), a cooperative
`TimerQueue` (`set_timeout`/`clear_timeout`/`run_pending_timers` — held then
fired explicitly, since a headless smoke has no ambient event loop), and
`is_buffer`. `src/stdin_buffer.jac` rewired onto it and now executes: raw
terminal bytes → discrete escape sequences, bracketed paste → `paste` event,
incomplete tail buffered then flushed on timer.

Two more runtime blockers surfaced and fixed in `stdin_buffer.jac` (converter is
upstream owner): a subclass whose `has` fields lacked defaults broke dataclass
field ordering under an inherited base (non-default after default); and this Jac
runtime **cannot lower a zero-arg `super()`** (`'super' object is not callable` /
native-lowering failure) — the emitted `super()` / `super().__init__()` in a
custom `__init__` must be replaced by seeding the inherited fields directly.

**Runtime smokes (all three green):**
- `smoke_pure.jac` — `fuzzyMatch`/`fuzzyFilter`, `graphemeWidth`, `visibleWidth`
  over ASCII/CJK/ANSI.
- `smoke_render.jac` — `Text` renders and wraps to a fixed-width buffer, CJK
  width budget honored, `Box` composes a child with vertical padding.
- `smoke_input.jac` — `StdinBuffer` segments ASCII / arrow (CSI) / SGR-mouse /
  mixed input, lifts bracketed paste into a `paste` event, and holds+flushes an
  incomplete CSI tail via the timer.

Run: `cd tui/pi_jac_floor && jac run smoke_pure.jac && jac run smoke_render.jac && jac run smoke_input.jac`.

Side effect: `components/text.jac` now checks clean (the utils type fixes
cascaded). The per-entry counts in `pi_jac_floor_summary.json` are stale
relative to this work and should be regenerated before being cited.

**`keys.jac` now checks clean AND runs** (`smoke_keys.jac`). The sequence→keyname
mapper takes a segmented escape sequence / control byte and returns a semantic
key name (`up`, `ctrl+a`, `alt+x`, `delete`, `shift+tab`, …). Chained onto
`stdin_buffer`, the pipeline is now **raw bytes → segments → named key events
end to end** (`smoke_keys.jac` drives both). 293 static errors were cleared
(dict `.attr`→`["attr"]` on the lookup globals, `String.fromCharCode`/
`fromCodePoint`→`chr`, `Number.isFinite`→`math.isfinite`, set `.has`→`in`, plus
cascade type casts and an optional-param default from keys.ts).

Six more **runtime-only** blockers surfaced after check passed (converter is
upstream owner; all recur across modules):
- **IIFE null-coalesce lambdas can't lower at runtime** — the converter lowers
  JS `a ?? b` to `(lambda (_x){ return _x if _x is not None else b; })(a)`, which
  crashes with `name '__jac_lambda_N' is not defined`. Rewrote all 4 to plain
  `(a if a is not None else b)` (or `.get(k, default)` when `a` was a dict miss).
- **JS `obj[key]` undefined-on-miss vs Jac dict `KeyError`** — three lookup
  sites indexed by arbitrary input (`LEGACY_SEQUENCE_KEY_IDS[data]`,
  `funcCodes[keyNum]`, `kitty["baseLayoutKey"]` where a branch omits the key)
  must use `.get(...)`; the JS truthiness check downstream expects `None`.
- **Object destructuring of a dict** — `matchesKey` read `parsed.key`/`.ctrl`/…
  off a `parseKeyId` dict typed `any`; static check allows attr-access on `any`
  but it's `KeyError` at runtime → `parsed["key"]` etc.
- **`String.fromCharCode` on a negative codepoint** — functional/arrow codepoints
  are negative; `chr(-3)` throws. JS coerces ToUint16, so the faithful mapping is
  `chr(x & 0xFFFF)`.

**`terminal.jac` now checks clean AND runs** (`smoke_terminal.jac`). This is the
real terminal boundary — the one module that genuinely drives the OS terminal.
Rather than a Node adapter, it needed a **POSIX** one (`src/terminal_support.jac`),
since the target is the CPython-backed `jac` runtime, not Node: `process.stdin`/
`stdout` (termios/tty raw mode against a real TTY, degrading to a flag + `feed()`
seam for the headless smoke; `os.get_terminal_size`, EventEmitter resize), `fs`/
`path`, `Date`/`now_ms`, `Number`, and cooperative `set_interval`/`clear_interval`
(held then fired via `run_pending_intervals`, mirroring input_support's timers).
`terminal.jac` was rewired onto it (293 static errors cleared). `native_modifiers.jac`
was cleaned up alongside: its macOS-only native-`.node` `require` loop can never
load under Jac, so it degrades to `False` exactly as on any non-macOS Node host.
The smoke drives kitty-protocol negotiation, the stdin→data→input-handler path,
the progress keepalive interval, cursor moves, and the full start/stop lifecycle.

Four more **runtime-only** blockers here (converter is upstream owner):
- **converter double-escapes hex in template literals** — JS `` `\x1b[3B` `` emitted
  `f"\\x1b[3B"` (literal backslash: 7 chars, not an ESC byte), so terminal escapes
  would print as visible text. Fixed to single-backslash `f"\x1b..."`.
- **`a || b || 80` fallback breaks on NaN** — `Number("")` is `nan` under Jac, which
  is **truthy** (unlike JS falsy NaN), so `columns()`/`rows()` never fell back.
  Rewrote to explicit branches with an `n == n` NaN reject.
- **reassigning a module `glob` inside a function → UnboundLocalError** — the
  `native_modifiers` cache-memo (`if g!=None: return g; g=…`) crashed; gutted.
- **`drainInput`'s `await Promise(setTimeout)` busy-wait** — no ambient event loop
  under headless `jac run`; became a real `time.sleep` (also fixed a captured-local
  reassignment in its `onData` lambda via a dict-state seam).

**`word_navigation.jac` now checks clean AND runs** (`smoke_word_nav.jac`).
`findWordBackward`/`findWordForward` were rewritten Jac-native, dropping the
JS idioms the converter left in place — `segments[Symbol.iterator]()`,
`String.matchAll(RegExp(PUNCTUATION, "g"))`, and `RegExp.exec` — for a plain
list walk over `utils.getWordSegmenter()` (the `unicode_support.WordSegmenter`
adapter) and stdlib `re.finditer`/`re.search` against `PUNCTUATION_REGEX`.
Two runtime-correctness fixes over the raw conversion, both from real caller
usage (input.jac passes no options; editor.jac passes a **dict** bag):
- **`options` is a dict, not a JS object** — the converted optional-chaining
  lambdas did attribute access (`options.segment`); callers pass
  `{"segment": …, "isAtomicSegment": …}`. Now read by key, defaulting to the
  WordSegmenter with no atomic segments when omitted.
- **segments come in two shapes** — the default path yields `Seg` objects
  (`.segment`/`.index`/`.isWordLike`), the editor's custom segmentFn yields
  marker **dicts** (`{"segment", "index"}`, no `isWordLike`). Accessors read
  either shape, so a marker dict is correctly treated as non-word-like.
The smoke covers the default segmenter (word/space/punctuation boundaries,
both directions, clamps) and the custom-options path (dict segments +
`isAtomicSegment` atomic runs).

**Editor word-motion wiring now runs** (`smoke_editor_wordmotion.jac`, 7th
green smoke). `editor.segmentWithMarkers` — the paste-marker segmenter that
feeds the editor's custom `segment` lambda into `findWordForward`/
`findWordBackward` — was rewritten Jac-native, dropping the JS idioms the
converter left in place: `validIds.size` → `len(validIds)`; `validIds.has(id)`
→ `id in validIds`; `text.matchAll(RE)` → `re.finditer(RE, text)`; match-object
`m[0]`/`m[1]`/`m.index` → `m.group(0)`/`m.group(1)`/`m.start()`; and attr-access
on the `{start,end}` marker dicts (`marker.end`) → key access (`marker["end"]`).
`int(m[1], 10)` (JS radix) → `int(m.group(1))`. `validPasteIds()` returns a
Python `set`, and paste ids are int-keyed, so int/float set membership resolves
correctly.

Importing `editor.jac` under the runtime forced three blocking fixes up its
import chain (all check-passing, all runtime crashes on import):
- **`tui.getKittyImageReservedRows`** had a JS per-call default arg
  `maxIndex = len(lines) - 1` referencing another parameter — invalid in
  Python (defaults bind at def-time). Sentinel `None` + in-body default.
- **`obj TUI(Container)`** declared non-defaulted `has terminal`/`renderTimer`
  after the base's defaulted `children` — a dataclass field-order error. Gave
  them `= None` defaults (the explicit `__init__` sets `terminal` anyway).
- **`undo_stack.UndoStack.push`** called the JS global `structuredClone`,
  whose failed native lowering demoted the method and broke the module import
  under the editor's compile context. Replaced with `copy.deepcopy`.

The smoke drives `segmentWithMarkers` (empty-validIds passthrough, a valid
paste marker collapsing to one dict segment, an invalid id staying split) and
the full word-motion path (marker treated as an atomic unit, jumped whole in
both directions).

Still unrun by design: anything downstream of `terminal-image`.

The five checking entry points are:

- `components/spacer.jac`
- `editor-component.jac`
- `fuzzy.jac`
- `terminal-colors.jac`
- `utils.jac`

Warnings are not counted as failures. The census classifies errors attributed to the entry file separately from errors reported in imported files. For example, `components/image.jac` reports 216 errors when checked as an entry point, but 194 are imported from `terminal-image.jac`. Similarly, `index.jac` reports 203 errors but only one is attributed directly to `index.jac`. Project-wide raw totals are therefore not a useful progress metric yet.

## Root-cause census

The 23 failing entry points reduce to eight actionable families. Counts below are affected entry points, not raw diagnostic counts; one file can belong to several families.

| Root cause | Affected shape/files | Owner | Disposition |
|------------|----------------------|-------|-------------|
| Invalid syntax/control-flow lowering | Directly concentrated in `terminal-image.jac`; its failures cascade through `components/image.jac`, `components/markdown.jac`, `tui.jac`, and `index.jac`. Examples include nested-quote f-strings, malformed `Buffer.from(...).toString(...)`, and parser fallout (`E0002`, `E0005`, `E0030`). | **js2jac** | Fix general emission rules. This is genuine incorrect lowering. |
| JS collection/object semantics left intact | `keybindings`, `keys`, `kill-ring`, `undo-stack`, autocomplete and component code: `.has`, `.find`, `.reduce`, `.unshift`, JS object dot access on emitted Jac dicts, `array.length = 0`, and `Object.entries`/Map-shaped loops. | **js2jac** | Add only general semantic mappings to Jac operations. Do not solve individual pi-tui call sites with special cases. |
| Identifier and object-layout incompatibility | `root` emitted unescaped in `components/editor`, `components/input`, `tui`, and the barrel; non-default fields emitted after default fields in `settings-list`, `markdown`, and `tui`. | **js2jac** | Escape Jac keywords and emit legal field order while preserving constructor behavior. |
| Numeric/type lowering and insufficient annotations | Most component and navigation modules: TypeScript `number` becomes `float` even where indexing/width APIs require `int`; unions collapse to imprecise dicts; locals/import results become `Unknown`, producing arithmetic, return, and overload errors. | **Mixed: js2jac + Jackal port** | Fix systematic source-type-to-Jac-type mistakes in the converter. Add domain types and deliberate annotations during porting; do not grow per-call converter heuristics. |
| Unsupported Node runtime APIs | `native-modifiers`, `terminal`, `stdin-buffer`, `terminal-image`, `keys`, and consumers use `process`, stdin/stdout, `Buffer`, `EventEmitter`, `node:child_process`, timers, and environment/runtime behavior. | **Jackal port** | Replace with deliberate server/Python-backed terminal adapters in `app/`. This is not converter work. |
| Unsupported JS/browser/package APIs | `Intl.Segmenter` in word navigation; `String.fromCharCode`, `Array`/`Object` globals; `marked`, image helpers, and terminal feature probing. | **Jackal port**, except general built-in mappings | Port algorithms and dependencies explicitly. Only broadly correct built-in mappings belong in js2jac. |
| Import/export and visibility fallout | `index.jac` has one direct diagnostic and 202 dependency diagnostics; component entry checks also replay errors from `terminal-image.jac` and other imports. Rewritten exports and shared type visibility remain unproven. | **js2jac for rewrite correctness; Jackal port for graph design** | Re-evaluate only after direct module errors are reduced. Do not use the current 203-error barrel total as a converter score. |
| Potential compiler/framework limitations | No diagnostic in this census is yet proven to require a Jac compiler or framework change. Candidates must be reduced to a minimal valid-Jac reproducer before handoff. | **Upstream Jac, unconfirmed** | Do not patch `jaclang`, `jac-ink`, or `jac-client`. Document a minimal reproducer and hand it to the human if a converter-correct construct still fails. |

## Per-entry triage

This table records the primary first fix, not every secondary error.

| Entry points | Primary root cause | First owner |
|--------------|--------------------|-------------|
| `undo-stack`, `kill-ring`, `keybindings` | JS collection mutation/API lowering | js2jac |
| `keys` | JS object/dict semantics plus runtime string/terminal APIs | js2jac, then Jackal port |
| `terminal-image` | Invalid emitted syntax, then Node/image runtime APIs | js2jac, then Jackal port |
| `native-modifiers`, `terminal`, `stdin-buffer` | Node process/stream/event runtime | Jackal port |
| `word-navigation` | `Intl.Segmenter` plus missing segment types | Jackal port |
| `autocomplete` | async/result type inference and JS collection semantics | mixed |
| `components/box`, `text`, `truncated-text`, `loader`, `cancellable-loader` | inferred/declared type incompatibilities and JS regex/collection APIs | mixed |
| `components/settings-list`, `select-list`, `input`, `editor` | field layout/keyword lowering plus domain types | js2jac, then Jackal port |
| `components/image`, `markdown`, `tui` | own type/API errors plus the `terminal-image` syntax cascade | mixed; unblock `terminal-image` first |
| `index` | barrel/export issue plus transitive cascade | js2jac; defer until leaves improve |

## Decision boundary

Broad converter feature expansion is frozen after zero-hole emission. A change belongs in js2jac only when the emitted Jac is generally and semantically wrong, such as malformed syntax, an unescaped Jac keyword, illegal field ordering, or a reusable incorrect mapping of a JavaScript operation. Node interop, terminal behavior, package replacement, domain modeling, and ordinary type refinement belong to the Jackal port.

The generated tree under `tui/pi_jac_floor/` remains migration/reference material. It does not replace the Jac-native product work under `app/`, and reaching 28/28 checks would not complete Roadmap N1.

## Next gates

1. Fix the general converter-owned errors, starting with `terminal-image.jac` syntax, reserved identifiers, field ordering, and collection mutations.
2. Re-run all 28 entry checks and record direct versus imported diagnostics. The next clean converter gate is 28/28 entry checks only if it can be reached without encoding Node-specific behavior into js2jac.
3. Check the complete module graph and then repair import/export rewrites, cycles, and shared type visibility.
4. Add focused behavioral parity tests for input buffering, key normalization, cursor/word movement, undo/kill-ring behavior, ANSI width, invalidation/rendering, async autocomplete serialization, and terminal cleanup/cancellation.
5. Prove an executable smoke slice with components, a virtual terminal, input, output, state, and cancellation.

## Artifacts and reproduction

| Path | Contents |
|------|----------|
| `tui/pi_jac_floor/` | Current 28-file, zero-hole emitted tree. |
| `tui/pi_jac_floor_summary.json` | Per-entry emission, hole, and check result from the conversion run. |
| `tui/pi_jac_floor_project_check.txt` | Whole-tree check output; useful for detail, not aggregate progress. |
| `tui/pi_jac/` | Earlier strict project-mode artifact; retained as conversion history. |

Re-run the conversion and checks with:

```bash
./tui/scripts/js2jac_pi_tui.sh
```

The script regenerates `pi_jac_floor/`, the summary, and the whole-tree check output. Its per-entry `jac check` follows resolvable imports; when diagnosing ownership, attribute each diagnostic to the file path in the diagnostic rather than to the entry command alone.
