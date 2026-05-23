Review the following Jac code for non-idiomatic patterns ("Python written in Jac").

**Scope:** {{paths}}

**Files to review:**

{{file_list}}

## Checklist (FR-9 idiom patterns)

For each file, read the source and report issues in a numbered list. Flag severity as **error** (will cause bugs or blocks OSP) or **warning** (style/idiom).

1. **Graph modeling**
   - Lists/arrays/dicts used to represent relationships instead of `edge` types and `++>` / `[-->]` traversal
   - Missing `visit [-->]` inside walker abilities (walker stops after first node)
   - Walkers invoked like functions (`MyWalker(node)`) instead of `MyWalker() spawn node`
   - Walkers without a `` `root entry `` ability when spawning from `root`

2. **OSP semantics**
   - Python `class` mental model applied to nodes/walkers (wrong ability placement, mutating `here` from outside abilities)
   - State-changing logic on the wrong side (should be on node when it depends on visiting walker, on walker when it depends on node type)

3. **Jac vs Python types**
   - `Optional[T]` instead of `T | None`
   - Missing `is None` checks before dereferencing optional references

4. **AI-native constructs**
   - Hidden or unexplained `by llm()` / AI calls without user-visible intent
   - AI calls that should be explicit walker abilities or documented `can` blocks

5. **Client components (if `.cl.jac`)**
   - `useState` / `useEffect` where `has` + `async can with entry` is idiomatic

## Output format

```
## Idiom review — <file>

| # | Line | Severity | Pattern | Suggestion |
|---|------|----------|---------|------------|
...
```

End with a short **summary**: total issues, highest-priority fix, and whether `validate_jac` should be run after fixes.

If no files were specified, scan `.jac` / `.cl.jac` files under the project (skip `node_modules`, `.git`, `.jac`, `dist`).
