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
| Independently checks | **5 / 28** | `jac check <module>` succeeds for the module entry point. Local imports are still followed, so dependency diagnostics can appear. |
| Module graph checks | **No** | `jac check tui/pi_jac_floor` fails; graph totals are dominated by downstream failures. |
| Runtime verified | **No** | No converted virtual-terminal/input/render smoke slice has run successfully. |

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
