#!/usr/bin/env bash
# Build the vendored Jac compiler (vendor/jac) into the editable dev binary.
#
# vendor/jac is a git subtree of jaseci-labs/jac (branch jac-one-compiler);
# see docs/VENDOR-JAC.md. Upstream's scripts/fresh_env.sh assumes it runs at
# the repository root (`git rev-parse --show-toplevel`), which inside a
# subtree resolves to the jackal root -- so this wrapper runs the same steps
# with explicit paths.
#
# Output: vendor/jac/jac/zig-out/bin/jac
#   -Ddev links the in-tree compiler source into the binary, so edits to
#   vendor/jac/jac/jaclang/** take effect with no rebuild.
#
# One-time downloads on a fresh machine (idempotent afterwards):
#   - pinned LLVM subset (~84 MB -> .llvm-build/)
#   - pinned bun runtime
#   - pinned python-build-standalone CPython (build host)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VJ="$REPO_ROOT/vendor/jac/jac"

command -v zig >/dev/null || { echo "error: zig 0.16.0 required but not on PATH" >&2; exit 1; }

cd "$VJ"
zig build fetch-llvm
zig build fetch-bun
zig build -Ddev -Dpayload-progress

echo
echo "Built: $VJ/zig-out/bin/jac"
echo "Put it first on PATH:  export PATH=\"$VJ/zig-out/bin:\$PATH\""
