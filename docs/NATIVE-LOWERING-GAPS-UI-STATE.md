# Native lowering gap report — OSP UI state modules (2026-08-25)

Attempted to lift `[placement.pins]` server pins for `ui.model`, `ui.mutation`,
`ui.events`, `ui.bindings` under `default_codespace = "native"` (vendored
compiler 0.36.1-dev). Outcome: **only `ui.bindings` lowers** (pin removed,
commit `fix(app/ui): lower ui.bindings natively`). The other three remain
server-pinned; their blockers are compiler gaps, not app-code annotation gaps.

## ui.model — BLOCKED: graph constructs

Module-level fallback: `error[E5092]: Native lowering failed for expression
'UnaryExpr'`. Per-function demotions observed:

| Construct | Evidence |
|---|---|
| Edge traversal filter `[edge parent ->:Child:-> child]` | `Native pathway does not yet support expression 'EdgeRefTrailer'` (model.jac:112, :129) |
| `jid(n)` builtin | `Native lowering failed for expression 'FuncCall'` (model.jac:99, `node_id`) |
| Backward traversal `[current <-:Child:<-]` | same EdgeRefTrailer class (inside `child_parent` / `enclosing_screen` / `is_child_ancestor`) |

The whole module is graph-native by design (`node UiNode*`, `edge Child` /
`Owns` / `Feeds` / `FocusNext` / `Layer`). `jac-native` docs list
"walkers/nodes/edges" as not supported in the native subset, so this is a
hard capability gap, not a typing issue.

## ui.mutation / ui.events — BLOCKED: same graph gap + walkers

- Both import `ui.model`'s node/edge types; placement solver anchors them
  server via the import-closure once model is server (no independent verdict).
- `mutation.jac`: edge connect/delete ops (`parent +>:Child(rank=r):+> child`,
  `del e`) — no native lowering path exists.
- `events.jac`: `walker UiEvent*` archetypes and `stop spawn event;`
  dispatch — walkers are explicitly outside the native subset.

**Recommended fix (jaclang):** native support for typed-edge storage +
traversal (`->:Edge:->` / `<-:Edge:<-`, `[edge ...]` filters), `jid()`, and
either walker lowering or an explicit structured-dispatch alternative.
Until then the three pins must stay.

## Compiler bugs hit while lowering ui.bindings (upstreamable)

1. **Keyed sorts emit invalid IR / mis-sort.**
   - `list[str].sort(key=f)` where f returns `str` → E5020 `icmp sgt
     %"JacStr"` (LLVM IR parse error) — primitives_native.impl.jac
     `emit_sort` compares struct values with integer icmp.
   - Key returning `tuple[str,str]` lowers to a heap-pointer return;
     `emit_sort`'s PointerType branch treats it as a C string and compares
     raw pointers → silently wrong order / duplicated elements.
   - Worked around in app code: replaced all `sort(key=...)` with a stable
     insertion sort using plain `<` on `str` fields (lowers correctly).
2. **Untyped `dict` lookups fail at runtime across function boundaries**
   (`d = {"aa": 1}; d["aa"]` → "key not found" when the dict crosses a call
   as `dict`); typed `dict[str, int]` works. Workaround: typed
   `dump_bindings -> list[dict[str, str]]`.
3. **`some_list == []` miscompares** (returns False for two empty lists when
   one side is an empty literal; variable-vs-variable compare works).
   Workaround: `len(x) == 0` in tests.
4. Attempted vendor fix delegating `emit_sort` comparisons to
   `_emit_comparison` (handles JacStr + lexicographic tuples): fixed all
   compile-time failures and tuple-key ordering, but obj-element lists
   segfaulted post-sort (RC/GC corruption suspected in sort swap path).
   **Reverted** — needs its own investigation before landing.
