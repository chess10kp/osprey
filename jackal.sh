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
# Legacy Ink support was removed. Use the native Jac paths below.

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
  --ink                unsupported; use the native TUI, --repl, or --json
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

The legacy Ink stack was removed. Use the native paths above.
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

  # JACKAL_MODE is validated by the launcher and consumed by the native
  # session seam. A command-line --mode (parsed below) overrides the env.
  exec jac run "$entry" "$@"
}

# ---- flag parsing -----------------------------------------------------------

JACKAL_MODE="${JACKAL_MODE:-}"
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

if [[ "$MODE_SEEN" == 1 || -n "$JACKAL_MODE" ]]; then
  case "$JACKAL_MODE" in
    normal|auto-accept|yolo|plan|ask) ;;
    *)
      echo "jackal: invalid --mode '$JACKAL_MODE' (expected normal, auto-accept, yolo, plan, or ask)" >&2
      exit 1
      ;;
  esac
  export JACKAL_MODE
fi

# ---- removed legacy Ink stack (--ink) ---------------------------------------

if [[ "${1:-}" == "--ink" ]]; then
  echo "jackal: --ink is no longer supported; the legacy Ink stack was deleted." >&2
  echo "Use ./jackal.sh for the native TUI, ./jackal.sh --repl, or ./jackal.sh --json." >&2
  exit 1
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
if [[ ! -t 0 || ! -t 1 ]]; then
  die_no_tty
fi

run_native tui.jac "$@"



# Unrecognized flag starting with '--': fail loudly rather than silently
# forwarding garbage to the TUI entry.
if [[ "${1:-}" == -* ]]; then
  echo "jackal: unknown option '$1' (try --help)" >&2
  exit 1
fi
