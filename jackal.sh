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

# Expose adapter dist path + the user's launch cwd to the facade.
export JACKAL_AGENT_DIST="$JACKAL_DIR/agent-next/dist/index.js"
export JACKAL_AGENT_CWD="${JACKAL_AGENT_CWD:-$PWD}"

# Compile-only first so we can swap the jac-ink @jac/pi stub for our real facade.
TUI_OUT="${JACKAL_TUI_OUT:-$JACKAL_DIR/agent-next/.jac/tui}"
(
  cd "$JACKAL_DIR/agent-next" \
    && jac tui templates/shell.cl.jac --with_pi --out "$TUI_OUT" --no_run
)

# Overwrite the jac-ink-emitted stub with our real adapter facade.
cp "$JACKAL_DIR/agent-next/templates/jac_pi_facade.mjs" "$TUI_OUT/jac_pi_runtime_shim.mjs"

# Install deps if needed, then launch.
if [[ ! -d "$TUI_OUT/node_modules" ]]; then
  (cd "$TUI_OUT" && npm install --ignore-scripts)
fi

# Ensure readline-capable input component is available in the generated Ink app.
if [[ ! -d "$TUI_OUT/node_modules/@inkjs/ui" ]]; then
  (cd "$TUI_OUT" && npm install --ignore-scripts @inkjs/ui)
fi

exec -a jackal node "$TUI_OUT/runner.mjs" "$@"
