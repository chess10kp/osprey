# Native lowering status — OSP UI state modules

**Updated:** 2026-08-30 after syncing `vendor/jac` to upstream Jac
`fe4b7c760ae55d8259ab8f9da7a879fd45aa135e`.

The 2026-08-25 report below was produced against the pre-graph-shaped native
compiler and is superseded for graph/walker capability. Upstream now carries a
native OSP kernel and equivalence coverage in
`vendor/jac/jac/jaclang/compiler/tests/test_osp_equivalence.jac`.

## Upstream capability

The synced native backend implements native lowering for:

- `spawn` / `visit` / `disengage` / `report` and entry/exit dispatch;
- typed and untyped edge traversal, edge references, disconnect, and
  predicate filters;
- subtype and tuple-trigger dispatch.

The implementation is in
`vendor/jac/jac/jaclang/compiler/backends/native/na_ir_gen/osp.impl.jac`.
The upstream equivalence suite marks the supported native cases with
`require=["na"]` or `require=["na", "cl"]`.

## Jackal status

The rebuilt vendored compiler was exercised against `app/ui/events.jac`.
The graph edge-reference forms in `app/ui/model.jac`, including explicit
endpoints such as `[edge parent ->:Child:-> child]`, no longer emit the old
`EdgeRefTrailer` unsupported diagnostic. The remaining demotion is `jid(n)`:
native lowering reports `FuncCall` at `model.jac:99`, so the model module has
no native artifact and `ui.events` remains server-placed.

The upstream OSP equivalence suite passes 30 tests and currently fails the
bound-endpoint fixture because its native arm also exercises `jid()` and
object-identity comparison. This is a narrower residual gap than the
pre-sync graph/walker blocker.

The current placement frontier is explicit in `app/jac.toml`: 15 modules remain
server-pinned, while N6 requires zero server pins. Edge-object and walker
lowering are landed; `jid()` native lowering/object identity is the immediate
remaining compiler gap. Lower-priority compiler gaps and Cordis integration are
deferred.

The historical compiler findings and workarounds follow. They remain useful
for primitive lowering, but must not be read as evidence that native OSP is
unsupported upstream.

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
