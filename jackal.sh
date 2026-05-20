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

# Set process name to 'jackal' for tmux window title
exec -a jackal pi \
  -e "$JACKAL_DIR/extensions/jackal-toolchain.ts" \
  --skill "$JACKAL_DIR/skills" \
  --prompt-template "$JACKAL_DIR/prompts" \
  "$@"
