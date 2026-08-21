# Differential rendering in pi-tui (Jac floor)

How `TUI.doRender()` turns layout changes into minimal ANSI patches, what can go wrong when inferring edit type from flat line buffers, and how that differs from widget-tree TUIs like Textual.

**Primary implementation:** `src/tui.jac`  
**Regression smokes:** `smoke_diff_append_vs_inplace.jac`, `smoke_diff_log_filler.jac`, `smoke_render.jac`

---

## Mental model

pi-tui is an **immediate-mode** differential renderer:

1. **Layout** — walk the component tree (header, log, spacer, status bar, overlays, …).
2. **Flatten** — produce `newLines: list[str]`, one string per terminal row.
3. **Diff** — compare `newLines` to `previousLines` (what was actually written last frame).
4. **Patch** — emit CSI cursor moves + line clears + text for the smallest region that covers the change.

The renderer’s memory is **`previousLines` only**: the last painted flat buffer. It does **not** retain which widget owns which row, widget identity, or layout rectangles.

```text
components  →  flatten  →  newLines
                              ↓
                    diff vs previousLines
                              ↓
              infer patch type (in-place / append / shift)
                              ↓
                    emit ESC sequences to stdout
```

This is deliberate: pi-tui (and the upstream `@earendil-works/pi-tui` it ports) targets low overhead and direct terminal control without a retained scene graph at the paint layer.

---

## Three patch strategies

Every frame, the diff logic must classify the change and pick a cursor/write strategy.

| Case | Example | Correct behavior |
|------|---------|------------------|
| **In-place repaint** | Status bar text changes | Move to that row, `\r`, clear line (`[2K`), rewrite one line |
| **Tail append** | New line at the very bottom; nothing above changed | Stay on last row, `\r\n`, write only new lines |
| **Insert + shift** | Log grows, spacer shrinks (same total height) | Rewrite from insertion point through the tail |

### In-place repaint

One row’s string changed at the same index; rows above and below are unchanged.

- Cursor: move to `firstChanged`, carriage return (no newline before the write).
- Clear: `\x1b[2K` on that row only.
- Typical trigger: status line update, single-line edit in a fixed slot.

### Tail append

Buffer grew; the first changed index is **at or past** the old buffer length. Nothing existing shifted.

- Cursor: already near the bottom; `\r\n` to step to the next row.
- Write: only the new tail rows.
- Cheapest path for streaming transcript growth when the log only extends downward.

### Insert + shift

Total line count may stay the same (or grow with internal rearrangement). Content was **inserted** in the middle; rows below the insertion point now show what used to be one row higher.

- Cannot use pure append — existing screen rows below the insertion are stale.
- Must repaint from `firstChanged` through `lastChanged` (often through end of buffer).
- Typical trigger: transcript gains a line while a `Spacer` shrinks to keep fixed viewport height.

---

## The log + spacer scenario (why shift detection exists)

Fixed-height layout:

```text
HEADER          row 0
log0            row 1     →  log0            row 1
                          →  log1            row 2   (new)
(spacer × 10)   rows 2–11 →  (spacer × 9)    rows 3–11
STATUS          row 12    →  STATUS          row 12
```

Total height stays **13 lines**.

### Naive line-by-line diff

| Index | previousLines | newLines | Equal? |
|-------|---------------|----------|--------|
| 0 | HEADER | HEADER | yes |
| 1 | log0 | log0 | yes |
| 2 | (spacer line 0) | **log1** | **no** ← firstChanged |
| 3 | (spacer line 1) | (spacer line 0) | **yes** ← looks unchanged |
| 4 | (spacer line 2) | (spacer line 1) | **yes** |
| … | … | … | yes |
| 12 | STATUS | STATUS | yes |

`lastChanged` stops at index 2. The patch rewrites row 2 only.

On the **physical terminal**, row 2 should show `log1`, but rows 3–11 still display **old** spacer content shifted wrong — and row 12 may still show stale pixels until the tail is redrawn. Identical filler strings at **shifted indices** compare equal even though their **screen meaning** changed.

### Shift signature

After the first change at index `i`, a shifted insert looks like:

```text
newLines[j] == previousLines[j - 1]   for j > i
```

`_tail_shifted_after()` in `tui.jac` detects this pattern and extends `lastChanged` to the end of the buffer so the tail is repainted.

---

## Bugs fixed (2026-08)

### 1. Float CSI parameters

Cursor moves were emitted as `\x1b[10.0A` instead of `\x1b[10A`.

Jac numeric values are often floats; CSI numeric parameters must be **integers**. Many terminals ignore or mishandle decimal forms, so cursor positioning was unreliable.

**Fix:** `_csi_n(n)` wraps `int(n)` for every CSI numeric parameter.

### 2. Shifted inserts with constant line count

When the log gained a line and the spacer lost one:

- `appendedLines` was false (same total height).
- Line-by-line diff saw one changed row and stopped.
- Identical filler strings at shifted indices compared equal.
- Stale content remained on screen below the insertion.

**Fix:** `_tail_shifted_after()` + extend `lastChanged` through end of buffer when shift is detected.

### 3. `appendStart` too narrow

Tail-append mode (`\r\n` from cursor) only fired when `firstChanged == len(previousLines)` exactly.

Mid-buffer inserts correctly avoided append, but combined with (2) they also did not get a full tail redraw when needed.

**Fix:** `appendStart` uses `firstChanged >= len(previousLines)` so only **genuine** tail growth (first change entirely in new rows) uses the append cursor path.

---

## Key code locations

```text
src/tui.jac
  _csi_n()                  — integer CSI parameters
  _tail_shifted_after()     — detect content pushed down one row
  doRender() / diff block   — firstChanged, lastChanged, appendStart, patch emit
  previousLines             — last frame’s flat buffer (renderer memory)
```

Relevant diff logic (approximate line numbers; may drift):

- `_csi_n`, `_tail_shifted_after`: top of `tui.jac`
- `firstChanged` / `lastChanged` scan: ~1172–1204
- `appendStart` guard: ~1220–1226
- Patch emission (`\r` vs `\r\n`, `[2K`, cursor moves): ~1293+

---

## Regression smokes

| Smoke | What it proves |
|-------|----------------|
| `smoke_diff_append_vs_inplace.jac` | Middle-line edit touches one row with `[2K`; bottom append uses `\r\n` |
| `smoke_diff_log_filler.jac` | Log grow + spacer shrink (constant height) redraws tail (`[2K` count ≥ 2); status-only update touches one line; no float CSI (`.0` absent in output) |
| `smoke_render.jac` | Broader render path still green |

Run:

```bash
cd tui/pi_jac_floor
jac run smoke_diff_append_vs_inplace.jac
jac run smoke_diff_log_filler.jac
```

Captured stdout is asserted in smokes (`process.stdout.capture = True`) — useful when debugging patch shape without a real TTY.

---

## Textual (and retained-mode TUIs) vs pi-tui

### What Textual keeps

Textual maintains a **widget tree + layout + dirty state**:

```text
Screen
 ├─ Header          region: row 0
 ├─ Log             region: rows 1–2  (was 1–1 → marked dirty)
 ├─ Spacer          region: rows 3–11 (was 3–12 → marked dirty)
 └─ StatusBar       region: row 12
```

On change:

- Know **which widgets** changed (log, spacer).
- Know each widget’s **rectangle** on screen.
- Repaint those regions (or dirty descendants).
- Do **not** infer insert vs append from flattened strings.

The terminal is an output surface; the source of truth is the **structured stage**.

### What pi-tui keeps

Only `previousLines: list[str]` — the last flat picture.

On change:

- Re-flatten the whole tree.
- Diff two string lists.
- **Guess** patch type from index equality and heuristics (`appendedLines`, `_tail_shifted_after`, viewport/overlay bounds, kitty image rows, …).

### Comparison

| | Textual-style (retained) | pi-tui-style (immediate + diff) |
|--|--------------------------|----------------------------------|
| Memory | Widget tree, layout boxes, dirty flags | `previousLines` |
| On change | “Log widget dirty → repaint its region” | “Rows i–j might need work; infer why” |
| Insert detection | Structural (child height changed) | Heuristic (shift signature in flat diff) |
| Failure mode | Layout bug in one widget | False “unchanged” when content **shifted** but index-wise strings match |
| Strength | Correctness by construction | Minimal bytes, no scene graph at paint layer |

The comment in the original fix notes: Textual avoids this class of bug by **asserting on widget state**. pi-tui must **reconstruct** edit semantics from two snapshots of a flat buffer — hence shift detection and careful `appendStart` bounds.

Ink (Jackal’s legacy shell) sits in the same broad family as Textual: React components, reconciliation, retained component tree — not the pi-tui flat-line diff model.

---

## When full redraw happens

Differential path is preferred; `fullRender()` is fallback when inference is unsafe or too hard. Triggers include (non-exhaustive):

- First frame (`previousLines` empty)
- Terminal width/height change
- `clearOnShrink` with buffer shorter than `maxLinesRendered`
- Overlay removal shrinking buffer
- Viewport scroll edge cases, kitty image pre-clear would scroll, etc.

`TUI.fullRedraws()` counter in smokes verifies we stayed on the differential path.

---

## Debugging checklist

1. **Capture patch bytes** — enable stdout capture or log `buffer` before `terminal.write`.
2. **Check CSI shape** — no `.0` in numeric params; `\x1b[<int>A/B/G`.
3. **Compare buffers** — print `previousLines` vs `newLines` with indices for the failing frame.
4. **Classify the case** — in-place vs append vs shift; does `firstChanged`/`lastChanged` match?
5. **Shift test** — for constant height, scan `newLines[j] == previousLines[j-1]` after first change.
6. **Run targeted smokes** — add a minimal repro as a new `smoke_diff_*.jac` if the scenario isn’t covered.

---

## Related roadmap context

Jackal N1 calls for a differential renderer with virtual-terminal tests covering first render, append, mutation, shrink, resize, and overlays (`ROADMAP.md`). The pi-tui Jac floor is the ported reference implementation; these learnings apply directly to any custom renderer that diffs flat line buffers instead of retaining widget regions.

---

*Last updated: 2026-08-20 — shift detection, integer CSI, appendStart bounds; smokes `smoke_diff_log_filler`, `smoke_diff_append_vs_inplace`.*
