# TUI debug mistakes — ChatHistory is not defined (2026-05-23)

Notes from debugging a runtime `ChatHistory is not defined` error in the Jackal Ink shell. These are mistakes to avoid next time.

## 1. Chased the runtime error before checking compile output

**Symptom:** React/Ink stack trace pointing at `module.mjs:1114` — `ChatHistory` used but undefined.

**Mistake:** Treated this as a missing import, export, or post-process bug first.

**Should have done first:** Open `.jac/tui/module.mjs` and search for `Could not compile`. The file already contained:

```
// Warning: Could not compile .../templates/components/transcript.cl.jac
```

When a Jac component is missing at runtime, assume the `.cl.jac` source failed to compile unless proven otherwise.

## 2. Inspected post-process scripts before confirming the module compiled

**Mistake:** Read `scripts/fix-tui-module.mjs` and wondered whether it should inject `ChatHistory`.

**Reality:** `fix-tui-module.mjs` merges duplicate imports and patches known jac2ink emit bugs. It does not synthesize components that jac-ink failed to emit. If the symbol is used but never defined, the compile step failed upstream.

## 3. Missed the grep signal on first pass

**Signal:** `grep ChatHistory module.mjs` returned only one hit — the JSX call site — with no `function ChatHistory` and no export.

**Mistake:** Did not treat "symbol used exactly once" as strong evidence of a failed submodule compile.

**Rule:** One usage, zero definitions → compile failure or broken import path, not a bundler merge issue.

## 4. Wrote Python-style tuple unpacking in Jac

**Root cause in `transcript.cl.jac`:**

```jac
# Wrong — Jac parse error: "Expected 'in', got ','"
for i, msg in enumerate(messages) {

# Correct — match shell.cl.jac / userinput.cl.jac
for (i, msg) in enumerate(messages) {
```

Jac requires parentheses around the unpack target in `for` loops. This is easy to copy from Python habit.

**Compile symptom:** `jac tui ...` → `No bytecode found for transcript.cl.jac`; generated `module.mjs` gets a warning comment instead of the component body.

## 5. Validated isolated Jac in MCP without local import context

**Mistake:** Ran `validate_jac` on snippet text and got noisy "Module not found" warnings for `ink`, `.usermsg`, etc.

**Lesson:** Use project-local compile for TUI modules:

```bash
source .venv/bin/activate
jac tui templates/components/transcript.cl.jac --out /tmp/test --no_run
```

MCP validation is still useful for syntax errors (it caught the `for i, msg` issue) but not for jac-ink module resolution.

## 6. Tried to boot the full TUI in a non-TTY shell

**Mistake:** Ran `./jackal.sh` in CI-style environments expecting a clean boot.

**Expected failure:** Ink raw mode error on stdin without a real terminal.

**Correct verification split:**

- Compile: `jac tui templates/shell.cl.jac --out .jac/tui --no_run` + `jackal.sh` post-process (`fix-tui-module.mjs`, `node --check`)
- Runtime adapter: `./jackal.sh --check`
- Interactive UI: real terminal only

## 7. jac2ink enumerate tuple names must use `f` for the value

**Symptom:** Runtime `ReferenceError: msg is not defined` (or `c is not defined`) inside loops compiled from `for (i, msg) in enumerate(...)`.

**Mistake:** Assumed Jac/Python tuple names survive jac2ink emit unchanged.

**Emit behavior:** jac2ink often emits `const [i, f] = _item` regardless of the Jac name for the second slot, while the loop body may still reference the original name — or worse, bind the wrong outer variable (e.g. `selected_index`).

**Workaround in Jackal `.cl.jac` sources:**

1. Name the enumerate value `f` and use `f` in the body.
2. Do **not** use `enumerate` in the same function as a selection index compared to `i` — jac2ink emits `const [i, sel_idx] = _item` (or `selected_index`) and leaves `f` undefined. Use a `range(len(...))` loop instead.

```jac
for (i, f) in enumerate(messages) {
    rows.append(<TranscriptRow key={"row-" + str(i)} msg={f} model={model}/>);
}
```

Applies anywhere jac2ink compiles `enumerate` with tuple unpacking (`transcript.cl.jac`, `CompletionsList`, `userinput.cl.jac`). ExplorerOverlay already used `(i, f)` and worked.

**Owner fix (jac-tui/jac-ink):** preserve Jac loop variable names in destructuring and loop body.


1. `grep "Could not compile" .jac/tui/module.mjs`
2. `grep -c "function X" .jac/tui/module.mjs` — expect ≥ 1
3. Compile the failing `.cl.jac` in isolation with `jac tui ... --no_run`
4. Compare Jac syntax with working siblings (`shell.cl.jac`, `userinput.cl.jac`) — especially `for (a, b) in enumerate(...)`
