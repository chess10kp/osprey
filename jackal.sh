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
#   ./jackal.sh [args...]  -> launch Jackal (Ink TUI + headless runtime)

if [[ "${1:-}" == "--pi" || "${JACKAL_CLASSIC_PI:-}" == "1" ]]; then
  cat >&2 <<EOF
jackal: the legacy Pi extension path was removed.

Use the Jackal shell instead:

  ./jackal.sh

Headless / CI:

  ./jackal.sh --check
  ./jackal.sh run "your prompt"

See docs/CONSOLIDATION_PLAN.md for migration notes.
EOF
  exit 1
fi

run_smoke_check() {
  export JACKAL_AGENT_CWD="${JACKAL_AGENT_CWD:-$PWD}"
  if [[ ! -f "$JACKAL_DIR/dist/index.js" ]]; then
    (cd "$JACKAL_DIR" && npm run build:agent >/dev/null)
  fi
  exec -a jackal node "$JACKAL_DIR/dist/index.js" --check "$@"
}

# Headless smoke/CI — no Ink compile or TUI boot.
if [[ "${1:-}" == "--check" ]]; then
  shift
  run_smoke_check "$@"
fi

# Parse --mode before branching (applies to TUI and `jackal run`).
JACKAL_MODE=""
filtered_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      if [[ -z "${2:-}" ]]; then
        echo "jackal: --mode requires a value (normal, auto-accept, yolo, plan)" >&2
        exit 1
      fi
      JACKAL_MODE="$2"
      shift 2
      ;;
    --mode=*)
      JACKAL_MODE="${1#--mode=}"
      shift
      ;;
    *)
      filtered_args+=("$1")
      shift
      ;;
  esac
done

if [[ -n "$JACKAL_MODE" ]]; then
  case "$JACKAL_MODE" in
    normal|auto-accept|yolo|plan) ;;
    *)
      echo "jackal: invalid --mode '$JACKAL_MODE' (expected normal, auto-accept, yolo, or plan)" >&2
      exit 1
      ;;
  esac
  export JACKAL_MODE
fi

set -- "${filtered_args[@]}"

if [[ "${1:-}" == "run" && "${2:-}" == "--check" ]]; then
  shift 2
  run_smoke_check "$@"
fi

run_headless() {
  export JACKAL_AGENT_CWD="${JACKAL_AGENT_CWD:-$PWD}"
  if [[ ! -f "$JACKAL_DIR/dist/index.js" ]]; then
    (cd "$JACKAL_DIR" && npm run build:agent >/dev/null)
  fi
  exec -a jackal node "$JACKAL_DIR/dist/index.js" "$@"
}

# Headless single-shot — no Ink compile or TUI boot.
if [[ "${1:-}" == "run" ]]; then
  run_headless "$@"
fi

# Build adapter on demand for the next shell.
if [[ ! -f "$JACKAL_DIR/dist/index.js" ]]; then
  (cd "$JACKAL_DIR" && npm run build:agent >/dev/null)
fi

# Expose adapter dist path + the user's launch cwd to the facade.
export JACKAL_AGENT_DIST="$JACKAL_DIR/dist/index.js"
export JACKAL_AGENT_CWD="${JACKAL_AGENT_CWD:-$PWD}"

# Avoid noisy desktop plugin load warnings in CLI environments.
if [[ -z "${JAC_DISABLED_PLUGINS:-}" ]]; then
  export JAC_DISABLED_PLUGINS="jac-desktop:desktop"
else
  export JAC_DISABLED_PLUGINS="${JAC_DISABLED_PLUGINS},jac-desktop:desktop"
fi

# Compile-only; swap jac-ink's @jac/pi stub for the Jackal agent runtime facade.
TUI_OUT="${JACKAL_TUI_OUT:-$JACKAL_DIR/.jac/tui}"
SHELL_SRC="$JACKAL_DIR/templates/shell.cl.jac"

die_no_jac_ink() {
  cat >&2 <<EOF
jackal: cannot compile the Ink shell — the jac-ink plugin is not installed.

  Your \`jac\` does not provide \`jac tui\` (needed for templates/shell.cl.jac).

Install jac-ink (same Python env as \`jac\`):

  ./scripts/setup-jac-ink.sh

Or manually:

  git clone https://github.com/jaseci-labs/jac-tui.git ~/repos/jac-tui
  python3 -m venv .venv && source .venv/bin/activate
  pip install -e ~/repos/jac-tui/jac-ink
  pip install jaclang
  jac tui --help    # must succeed

Headless modes work without jac-ink:

  ./jackal.sh --check
  ./jackal.sh run "your prompt"
EOF
  exit 1
}

has_jac_ink() {
  jac tui --help >/dev/null 2>&1
}

compile_tui() {
  (
    cd "$JACKAL_DIR"
    jac tui "$SHELL_SRC" --out "$TUI_OUT" --no_run --quiet
  )
}

postprocess_tui() {
  # jac-ink may inject legacy @jac/pi hook names; align with Jackal exports.
  sed -i \
    -e 's/usePiBoot/useJackalBoot/g' \
    -e 's/usePiSession/useJackalSession/g' \
    -e 's/useExtensionUI/useJackalUI/g' \
    "$TUI_OUT/module.mjs"

  # Work around a jac2ink codegen bug: missing closing brace in CompletionsList.
  perl -0pi -e 's/(rows\.push\(__jacJsx\(Text, \{"color": "cyan", "bold": is_sel\}, \[\(icon \+ label\)\]\)\);\n\s*)(return __jacJsx\(Box, \{"flexDirection": "column", "paddingX": 1\}, \[__jacJsx\(Text, \{"dimColor": true\}, \["Completions:"\]\), rows\]\);)/$1  }\n  $2/s' "$TUI_OUT/module.mjs"

  cp "$JACKAL_DIR/templates/jackal_agent_facade.mjs" "$TUI_OUT/jac_pi_runtime_shim.mjs"
  node "$JACKAL_DIR/scripts/dedupe-jac-runtime.mjs" "$TUI_OUT/module.mjs"
  node --check "$TUI_OUT/module.mjs" >/dev/null
}

if [[ "${JACKAL_SKIP_TUI_COMPILE:-}" == "1" ]]; then
  if [[ ! -f "$TUI_OUT/module.mjs" || ! -f "$TUI_OUT/runner.mjs" ]]; then
    echo "jackal: JACKAL_SKIP_TUI_COMPILE=1 but no cached TUI at $TUI_OUT" >&2
    exit 1
  fi
  echo "jackal: skipping TUI compile (JACKAL_SKIP_TUI_COMPILE=1)" >&2
elif has_jac_ink; then
  if ! compile_tui; then
    echo "jackal: jac tui compile failed for $SHELL_SRC" >&2
    if [[ -f "$TUI_OUT/module.mjs" && -f "$TUI_OUT/runner.mjs" ]]; then
      echo "jackal: using cached TUI at $TUI_OUT (may be stale)" >&2
    else
      die_no_jac_ink
    fi
  fi
  postprocess_tui
elif [[ -f "$TUI_OUT/module.mjs" && -f "$TUI_OUT/runner.mjs" ]]; then
  echo "jackal: warning: jac-ink not installed; using cached TUI at $TUI_OUT" >&2
  echo "jackal: run ./scripts/setup-jac-ink.sh to recompile after editing shell.cl.jac" >&2
  postprocess_tui
else
  die_no_jac_ink
fi

# Install deps if needed, then launch.
if [[ ! -d "$TUI_OUT/node_modules" ]]; then
  (cd "$TUI_OUT" && npm install --ignore-scripts)
fi

# Ensure readline-capable input component is available in the generated Ink app.
if [[ ! -d "$TUI_OUT/node_modules/@inkjs/ui" ]]; then
  (cd "$TUI_OUT" && npm install --ignore-scripts @inkjs/ui)
fi

exec -a jackal node "$TUI_OUT/runner.mjs" "$@"
