#!/usr/bin/env bash
# Install jac-ink into a venv so `jac tui` can compile shell.cl.jac.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JACKAL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
JAC_TUI_DIR="${JAC_TUI_DIR:-$HOME/repos/jac-tui}"
VENV_DIR="${JACKAL_VENV:-$JACKAL_DIR/.venv}"

if [[ ! -d "$JAC_TUI_DIR/jac-ink" ]]; then
  echo "error: jac-ink not found at $JAC_TUI_DIR/jac-ink" >&2
  echo "Clone jac-tui: git clone https://github.com/jaseci-labs/jac-tui.git $JAC_TUI_DIR" >&2
  exit 1
fi

if [[ ! -d "$VENV_DIR" ]]; then
  python3 -m venv "$VENV_DIR"
fi

# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"

python -m pip install -U pip wheel
python -m pip install -e "$JAC_TUI_DIR/jac-ink"

if ! jac tui --help >/dev/null 2>&1; then
  echo "error: jac tui still unavailable after installing jac-ink" >&2
  echo "Ensure jaclang is installed in this venv: pip install jaclang" >&2
  exit 1
fi

echo ""
echo "jac-ink OK. Activate before running Jackal:"
echo "  source $VENV_DIR/bin/activate"
echo "  cd $JACKAL_DIR && ./jackal.sh"
echo ""
echo "Or add to PATH:"
echo "  export PATH=\"$VENV_DIR/bin:\$PATH\""
