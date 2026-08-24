# Vendored Jac compiler (`vendor/jac`)

**Added:** 2026-08-24 · **Source:** `chess10kp/jaseci` branch `jac-one-compiler` @ `3730d76a2` (the jaseci-labs/jac PR #8370 stack) · **Form:** `git subtree --squash`

## Why a vendor copy

Jackal's native-completion path (see `~/notes/jackal-native-gap-analysis.md`, mirrored in `ROADMAP.md` §N5) needs fixes inside the Jac compiler itself: `na_stdlib` floors (`re`, `subprocess`, `threading`, `tempfile`, terminal FFI), lowering gaps (E1032/E5092), and IR-gen work. Upstream PR review latency is weeks — we cannot block product work on it. So the compiler lives here:

- **Fix now, in-repo**: any native-path fix lands in `vendor/jac/**` and the dev binary picks it up immediately.
- **PR upstream in parallel**: the same change goes to jaseci-labs/jac; when it eventually merges we sync and drop our local copy.
- **No waiting**: divergence is paid down on *our* schedule, not upstream's.

## Layout

```
vendor/jac/                  # upstream repo root (subtree root)
├── jac/                     # the compiler package
│   ├── build.zig            # one-command entry (fetch-llvm, fetch-bun, -Ddev, release)
│   ├── jaclang/             # compiler source — edits here run live under -Ddev
│   │   ├── compiler/passes/native/   # na_ir_gen/, na_compile_pass, LLVM shim
│   │   └── runtimelib/na_stdlib/     # native stdlib floors (json, os.path, ssl, ...)
│   ├── launcher/            # single-binary launcher internals
│   └── native/              # llvmlite FFI shim (C++, verbatim upstream)
└── scripts/                 # upstream helpers (fresh_env.sh — see gotchas)
```

`vendor/jac` maps the upstream **repo root** 1:1, so upstream file paths need no translation when reading upstream READMEs or syncing.

## Build

```bash
./scripts/setup-vendor-jac.sh     # wrapper — see gotchas below
export PATH="$PWD/vendor/jac/jac/zig-out/bin:$PATH"
jac --version
```

Requirements: zig 0.16.0, network for the one-time pinned fetches (LLVM slice ~84 MB, bun, pbs CPython). The `-Ddev` binary **links the in-tree compiler source live**: edit `vendor/jac/jac/jaclang/**` and re-run — no rebuild. Rebuild only for launcher `.zig`, `sitecustomize.py`/`_jac_finder.py`, or bundled-CPython changes.

## Editing rules

1. Fixes must stay **upstream-able**: conventional commits, no co-author lines, no gratuitous divergence from upstream structure.
2. Keep changes confined to the native path we depend on; if a change would conflict with upstream direction, stop and document it here instead.
3. When an upstream PR containing our fix merges, sync (below) and revert our local copy of the fix in the same change.

## Sync from upstream

```bash
# from the local compiler checkout (fast) or the fork on GitHub
git subtree pull --prefix=vendor/jac /home/jac/repos/jac-one-compiler jac-one-compiler --squash
# resolve conflicts inside vendor/jac/**, commit the merge
```

## Push a fix upstream

```bash
git subtree split --prefix=vendor/jac --branch vendor-jac-upstream
git push git@github.com:chess10kp/jaseci.git vendor-jac-upstream:<pr-branch>
# open PR against jaseci-labs/jac from the fork
```

## Gotchas

- **`git show-toplevel` breaks inside a subtree.** Upstream scripts that resolve the repo root this way (`scripts/fresh_env.sh`, possibly others) resolve to the *jackal* root when run from `vendor/jac`. Use `scripts/setup-vendor-jac.sh` (which runs the same `zig build` steps with explicit paths) instead of editing the vendored script.
- **Upstream `.gitignore` came along** and covers build products inside the subtree (`.llvm-build/`, `zig-out/`, `.payload-layers/`, `_bun/`, `zig-cache/`). Tracked content is ~28 MB; the multi-GB caches are all ignored.
- **`jac precommit --install`** (part of upstream fresh_env) installs git hooks into whatever repo root it finds — that would be jackal. Optional; skip unless wanted: it formats staged `.jac` files and blocks AI co-author lines.
- **Installed `jac` (0.36.1, pip/`~/.local/bin`) is separate.** Shadow it with `export PATH=.../vendor/jac/jac/zig-out/bin:$PATH` when working on native lowering, or CI/probes will test the wrong compiler.
- **Upstream is slow-moving for us**: never base app/ features on unmerged-upstream behavior *without* the vendor fix present — the vendor is the source of truth for what jackal builds against.

## Relationship to the native roadmap

The gap analysis (`~/notes/jackal-native-gap-analysis.md`) lists the concrete upstream work items; they land as:

| Gap | Where it lands |
|---|---|
| `na_stdlib` modules (`re`, `threading`, `subprocess`, `tempfile`, `queue`, terminal FFI floors) | `vendor/jac/jac/jaclang/runtimelib/na_stdlib/` |
| compiler intercepts (`os.environ`, `os.listdir`, `walk`, ...) | `vendor/jac/jac/jaclang/compiler/passes/native/na_ir_gen/` |
| lowering failures (E1032, E5092) | same passes + `na_compile_pass` |
| new-module congruence tests | `vendor/jac/jac/jaclang/compiler/tests/fixtures/` + `test_prim_equivalence.jac` |
