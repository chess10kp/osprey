#!/usr/bin/env bash
set -euo pipefail

# Jackal launcher.
#
# DEFAULT: boot the native Jac TUI (app/tui.jac).
#   ./jackal.sh                 interactive TUI (needs a real TTY)
#
# Native headless:
#   ./jackal.sh --repl          line REPL on stdio (app/main.jac)
#   ./jackal.sh --json          JSONL protocol on stdio (app/main.jac -- --json)
#
# Legacy Ink stack (DEPRECATED — pending removal):
#   ./jackal.sh --ink           Ink TUI + TypeScript runtime
#   ./jackal.sh --ink run "..." headless one-shot
#   ./jackal.sh --ink --check   CI smoke test

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

# Env the native harness reads (see app/agent/*.jac):
#   JACKAL_AGENT_DIR  auth.json resolution (app/agent/auth.jac) + skills,
#                     subagents, chains catalogs
#   JACKAL_ROOT       fallback catalog root when AGENT_DIR is unset
#   JACKAL_MODEL      default model (app/agent/session.jac)
#   JACKAL_CONTEXT_MAX context window override (app/agent/session.jac)
#   JACKAL_NODE_BIN   Node binary for the plugin-host sidecar
export JACKAL_AGENT_DIR="$PI_DIR"
export JACKAL_ROOT="${JACKAL_ROOT:-$JACKAL_DIR}"

if [[ "${1:-}" == "--pi" || "${JACKAL_CLASSIC_PI:-}" == "1" ]]; then
  cat >&2 <<EOF
jackal: the legacy Pi extension path was removed.

Use the Jackal shell instead:

  ./jackal.sh

See docs/CONSOLIDATION_PLAN.md for migration notes.
EOF
  exit 1
fi

usage() {
  cat <<EOF
usage: ./jackal.sh [options]

options:
  (default)            launch the native Jac TUI (interactive; needs a TTY)
  --repl               native line REPL on stdio (headless)
  --json               native JSONL protocol on stdio (headless)
  --mode MODE          dev mode: normal|auto-accept|yolo|plan|ask
  --ink                run the DEPRECATED legacy Ink stack (pending removal)
  --help               this help

env: JACKAL_AGENT_DIR, JACKAL_ROOT, JACKAL_MODEL, JACKAL_CONTEXT_MAX,
     JACKAL_NODE_BIN, JACKAL_MODE
EOF
}

die_no_tty() {
  cat >&2 <<EOF
jackal: the native TUI needs a real terminal (stdin/stdout are not a TTY).

Headless options at HEAD:

  ./jackal.sh --repl            line REPL on stdio
  ./jackal.sh --json            JSONL protocol on stdio
                                (one JSON object per line in, events out)

Legacy (deprecated, pending removal):

  ./jackal.sh --ink run "your prompt"
  ./jackal.sh --ink --check

NOTE: at time of writing, the native headless entries (--repl/--json) exec
correctly but app/main.jac fails to boot (agent.session imports do not bind
— 'session_boot' NameError). Legacy --ink headless modes remain reliable.
EOF
  exit 1
}

require_jac() {
  if ! command -v jac >/dev/null 2>&1; then
    echo "jackal: 'jac' binary not found on PATH — the Jac toolchain is required." >&2
    exit 1
  fi
}

run_native() {
  local entry="$1"
  shift

  # Avoid noisy desktop plugin load warnings in CLI environments.
  if [[ -z "${JAC_DISABLED_PLUGINS:-}" ]]; then
    export JAC_DISABLED_PLUGINS="jac-desktop:desktop"
  else
    export JAC_DISABLED_PLUGINS="${JAC_DISABLED_PLUGINS},jac-desktop:desktop"
  fi

  require_jac
  cd "$JACKAL_DIR/app"

  # Imports inside the app resolve siblings relative to app/.
  export JACPATH="${JACPATH:-.}"

  # NOTE: the native shell does not read JACKAL_MODE yet (grep app/ for
  # environ/getenv — only JACKAL_MODEL/JACKAL_CONTEXT_MAX/JACKAL_AGENT_DIR/
  # JACKAL_ROOT/JACKAL_NODE_BIN are consumed). We still accept and export
  # --mode so day-one mode wiring can land without launcher changes; until
  # then this flag is inert on the native path (use --ink for mode support).
  exec jac run "$entry" "$@"
}

# ---- flag parsing -----------------------------------------------------------

JACKAL_MODE=""
MODE_SEEN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --mode)
      if [[ -z "${2:-}" ]]; then
        echo "jackal: --mode requires a value (normal, auto-accept, yolo, plan, ask)" >&2
        exit 1
      fi
      JACKAL_MODE="$2"
      MODE_SEEN=1
      shift 2
      ;;
    --mode=*)
      JACKAL_MODE="${1#--mode=}"
      MODE_SEEN=1
      shift
      ;;
    *)
      break
      ;;
  esac
done

if [[ "$MODE_SEEN" == 1 ]]; then
  case "$JACKAL_MODE" in
    normal|auto-accept|yolo|plan|ask) ;;
    *)
      echo "jackal: invalid --mode '$JACKAL_MODE' (expected normal, auto-accept, yolo, plan, or ask)" >&2
      exit 1
      ;;
  esac
  export JACKAL_MODE
fi

# ---- legacy Ink stack (--ink) -----------------------------------------------

# Forward everything after --ink verbatim; dispatch happens at the bottom
# (after the pipeline is defined).
INK_MODE=0
INK_ARGS=()
if [[ "${1:-}" == "--ink" ]]; then
  shift
  INK_MODE=1
  INK_ARGS=("$@")
  set --
fi

# ---- native paths -----------------------------------------------------------

case "${1:-}" in
  --repl)
    shift
    # Headless line REPL — no TTY required.
    run_native main.jac "$@"
    ;;
  --json)
    shift
    # Headless JSONL protocol — no TTY required.
    run_native main.jac -- --json "$@"
    ;;
esac

# Default: interactive native TUI. tui.jac re-checks the TTY itself; we check
# first so the launcher can point at working headless alternatives.
if [[ "$INK_MODE" != 1 ]]; then
  if [[ ! -t 0 || ! -t 1 ]]; then
    die_no_tty
  fi

  run_native tui.jac "$@"
fi

ink_main() {
  cat >&2 <<EOF
jackal: WARNING — the Ink TUI stack is DEPRECATED and pending removal.
        The default launcher now boots the native Jac TUI (./jackal.sh).
EOF

  # Node defaults to ~2GB heap; long Jackal sessions can exceed that.
  jackal_node() {
    local heap_mb="${JACKAL_HEAP_MB:-4096}"
    if [[ -z "${NODE_OPTIONS:-}" ]]; then
      NODE_OPTIONS="--max-old-space-size=${heap_mb}"
    elif [[ "$NODE_OPTIONS" != *"max-old-space-size"* ]]; then
      NODE_OPTIONS="${NODE_OPTIONS} --max-old-space-size=${heap_mb}"
    fi
    export NODE_OPTIONS
    exec -a jackal node "$@"
  }

  run_smoke_check() {
    export JACKAL_AGENT_CWD="${JACKAL_AGENT_CWD:-$PWD}"
    if [[ ! -f "$JACKAL_DIR/dist/index.js" ]]; then
      (cd "$JACKAL_DIR" && npm run build:agent >/dev/null)
    fi
    jackal_node "$JACKAL_DIR/dist/index.js" --check "$@"
  }

  # Headless smoke/CI — no Ink compile or TUI boot.
  if [[ "${1:-}" == "--check" ]]; then
    shift
    run_smoke_check "$@"
  fi

  if [[ "${1:-}" == "run" && "${2:-}" == "--check" ]]; then
    shift 2
    run_smoke_check "$@"
  fi

  run_headless() {
    export JACKAL_AGENT_CWD="${JACKAL_AGENT_CWD:-$PWD}"
    if [[ ! -f "$JACKAL_DIR/dist/index.js" ]]; then
      (cd "$JACKAL_DIR" && npm run build:agent >/dev/null)
    fi
    jackal_node "$JACKAL_DIR/dist/index.js" "$@"
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

  ./jackal.sh --ink --check
  ./jackal.sh --ink run "your prompt"
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

    cp "$JACKAL_DIR/templates/jackal_agent_facade.mjs" "$TUI_OUT/jac_pi_runtime_shim.mjs"
    cp "$JACKAL_DIR/templates/markdown.mjs" "$TUI_OUT/markdown.mjs"
    cp "$JACKAL_DIR/templates/text-wrapping.mjs" "$TUI_OUT/text-wrapping.mjs"
    cp "$JACKAL_DIR/templates/diff_engine_node.mjs" "$TUI_OUT/diff_engine_node.mjs"
    node "$JACKAL_DIR/scripts/dedupe-jac-runtime.mjs" "$TUI_OUT/module.mjs"
    node "$JACKAL_DIR/scripts/fix-tui-module.mjs" "$TUI_OUT/module.mjs"
    node "$JACKAL_DIR/scripts/patch-tui-runner.mjs" "$TUI_OUT/runner.mjs"
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

  # Ensure syntax highlighting is available for the markdown renderer.
  if [[ ! -d "$TUI_OUT/node_modules/cli-highlight" ]]; then
    (cd "$TUI_OUT" && npm install --ignore-scripts cli-highlight)
  fi

  # Ensure table rendering is available for the markdown renderer.
  if [[ ! -d "$TUI_OUT/node_modules/cli-table3" ]]; then
    (cd "$TUI_OUT" && npm install --ignore-scripts cli-table3)
  fi

  jackal_node "$TUI_OUT/runner.mjs" "$@"
}

if [[ "$INK_MODE" == 1 ]]; then
  ink_main "${INK_ARGS[@]}"
fi

# Unrecognized flag starting with '--': fail loudly rather than silently
# forwarding garbage to the TUI entry.
if [[ "${1:-}" == -* ]]; then
  echo "jackal: unknown option '$1' (try --help)" >&2
  exit 1
fi
