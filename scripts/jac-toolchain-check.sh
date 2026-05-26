#!/usr/bin/env bash
# Jac migration CI check — toolchain + npm agent loop (parallel to ./jackal.sh --check).
# Requires: jac on PATH, node, npm ci (node_modules with pi-agent-core).
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
JACKAL_DIR="$(cd "$(dirname "$(readlink -f "$SCRIPT_PATH")")/.." && pwd)"
cd "$JACKAL_DIR"

if ! command -v jac >/dev/null 2>&1; then
  echo "FAIL: jac not on PATH (install jaclang: pip install jaclang)" >&2
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "FAIL: node not on PATH" >&2
  exit 1
fi

if [[ ! -d node_modules/@earendil-works/pi-agent-core ]]; then
  echo "FAIL: node_modules missing — run: npm ci" >&2
  exit 1
fi

echo "=== lib/jac check (toolchain + npm agent loop) ==="
jac run lib/jac/main.jac -- --check "$@"

echo ""
"$JACKAL_DIR/scripts/jac-test-harness.sh"
