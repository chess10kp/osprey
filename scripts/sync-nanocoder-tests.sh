#!/usr/bin/env bash
# Download nanocoder spec files into reference/nanocoder-tests for traceability.
# Jackal runs ported cases from tests/tui/*.test.mjs — these upstream files are reference only.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/reference/nanocoder-tests"
REPO="Nano-Collective/nanocoder"
BRANCH="main"

SPECS=(
  source/components/welcome-message.spec.tsx
  source/components/status.spec.tsx
  source/components/user-message.spec.tsx
  source/components/assistant-message.spec.tsx
  source/components/streaming-message.spec.tsx
  source/components/chat-queue.spec.tsx
  source/components/tool-message.spec.tsx
  source/components/user-input.spec.tsx
  source/app/components/chat-history.spec.tsx
  source/app/components/chat-input.spec.tsx
  source/app/components/modal-selectors.spec.tsx
  source/cli-harness.spec.ts
  source/cli-integration.spec.ts
)

mkdir -p "$OUT"

for spec in "${SPECS[@]}"; do
  dest="$OUT/$(basename "$spec")"
  gh api "repos/$REPO/contents/$spec?ref=$BRANCH" --jq '.content' | base64 -d > "$dest"
  echo "synced $spec"
done

cat > "$OUT/README.md" <<'EOF'
# Nanocoder test reference

Upstream AVA specs synced from [Nano-Collective/nanocoder](https://github.com/Nano-Collective/nanocoder).

Jackal runs **ported** equivalents in:

- `tests/tui/*.test.mjs` — ink-testing-library render tests
- `tests/adapter/*.test.ts` — runtime/CLI tests

Re-sync upstream specs:

```bash
./scripts/sync-nanocoder-tests.sh
```
EOF

echo "done — reference specs in $OUT"
