#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
JACKAL_DIR="$(cd "$(dirname "$(readlink -f "$SCRIPT_PATH")")" && pwd)"
PI_DIR="$JACKAL_DIR/pi"

# Symlink auth.json from global config so provider credentials carry over.
# This is a one-time setup — once created, it stays in sync automatically.
GLOBAL_AUTH="$HOME/.pi/agent/auth.json"
LOCAL_AUTH="$PI_DIR/auth.json"
if [ -f "$GLOBAL_AUTH" ] && [ ! -e "$LOCAL_AUTH" ]; then
  ln -s "$GLOBAL_AUTH" "$LOCAL_AUTH"
fi

export JACKAL_AGENT_DIR="$PI_DIR"

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
  export PI_CODING_AGENT_DIR="$PI_DIR"
  exec -a jackal pi \
    -e "$PI_DIR/extensions/jackal-toolchain.ts" \
    --skill "$PI_DIR/skills" \
    --prompt-template "$PI_DIR/prompts" \
    "$@"
fi

# Build adapter on demand for the next shell.
if [[ ! -f "$JACKAL_DIR/dist/index.js" ]]; then
  (cd "$JACKAL_DIR" && npm run build:agent >/dev/null)
fi

# Expose adapter dist path + the user's launch cwd to the facade.
export JACKAL_AGENT_DIST="$JACKAL_DIR/dist/index.js"
export JACKAL_AGENT_CWD="${JACKAL_AGENT_CWD:-$PWD}"

# Compile-only; swap jac-ink's @jac/pi stub for the Jackal agent runtime facade.
TUI_OUT="${JACKAL_TUI_OUT:-$JACKAL_DIR/.jac/tui}"
(
  cd "$JACKAL_DIR" \
    && jac tui templates/shell.cl.jac --out "$TUI_OUT" --no_run
)

# jac-ink may inject legacy @jac/pi hook names; align with Jackal exports.
sed -i \
  -e 's/usePiBoot/useJackalBoot/g' \
  -e 's/usePiSession/useJackalSession/g' \
  -e 's/useExtensionUI/useJackalUI/g' \
  "$TUI_OUT/module.mjs"

# Overwrite the jac-ink-emitted stub with the Jackal runtime facade.
cp "$JACKAL_DIR/templates/jackal_agent_facade.mjs" "$TUI_OUT/jac_pi_runtime_shim.mjs"

# Install deps if needed, then launch.
if [[ ! -d "$TUI_OUT/node_modules" ]]; then
  (cd "$TUI_OUT" && npm install --ignore-scripts)
fi

# Ensure readline-capable input component is available in the generated Ink app.
if [[ ! -d "$TUI_OUT/node_modules/@inkjs/ui" ]]; then
  (cd "$TUI_OUT" && npm install --ignore-scripts @inkjs/ui)
fi

exec -a jackal node "$TUI_OUT/runner.mjs" "$@"
