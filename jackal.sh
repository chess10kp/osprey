#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
JACKAL_DIR="$(cd "$(dirname "$(readlink -f "$SCRIPT_PATH")")" && pwd)"
AGENT_DIR="$JACKAL_DIR/jackal"

# Symlink auth.json from global config so provider credentials carry over.
# This is a one-time setup — once created, it stays in sync automatically.
GLOBAL_AUTH="$HOME/.pi/agent/auth.json"
LOCAL_AUTH="$AGENT_DIR/auth.json"
if [ -f "$GLOBAL_AUTH" ] && [ ! -e "$LOCAL_AUTH" ]; then
  ln -s "$GLOBAL_AUTH" "$LOCAL_AUTH"
fi

export PI_CODING_AGENT_DIR="$AGENT_DIR"

# Usage:
#   ./jackal.sh                 -> launch next TUI shell (default)
#   ./jackal.sh --pi [args...]  -> launch classic Pi TUI with Jackal extension
#   JACKAL_CLASSIC_PI=1 ./jackal.sh [args...] -> same as --pi
USE_CLASSIC=0
if [[ "${1:-}" == "--pi" ]]; then
  USE_CLASSIC=1
  shift
fi
if [[ "${JACKAL_CLASSIC_PI:-}" == "1" ]]; then
  USE_CLASSIC=1
fi

if [[ "$USE_CLASSIC" == "1" ]]; then
  exec -a jackal pi \
    -e "$JACKAL_DIR/extensions/jackal-toolchain.ts" \
    --skill "$JACKAL_DIR/skills" \
    --prompt-template "$JACKAL_DIR/prompts" \
    "$@"
fi

# Build adapter on demand for the next shell.
if [[ ! -f "$JACKAL_DIR/agent-next/dist/index.js" ]]; then
  (cd "$JACKAL_DIR" && npm run build:agent >/dev/null)
fi

exec -a jackal node "$JACKAL_DIR/agent-next/templates/shell.mjs" "$@"
