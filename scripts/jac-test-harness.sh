#!/usr/bin/env bash
# Run Jac unit tests in lib/jac/tests in isolated per-file invocations.
# Kept separate from lib/jac/main.jac --check so jac-check parsing never
# mistakes test string literals for real diagnostics.
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
JACKAL_DIR="$(cd "$(dirname "$(readlink -f "$SCRIPT_PATH")")/.." && pwd)"
cd "$JACKAL_DIR"

if ! command -v jac >/dev/null 2>&1; then
  echo "FAIL: jac not on PATH (install jaclang: pip install jaclang)" >&2
  exit 1
fi

collect_tests() {
  local target="$1"
  if [[ -f "$target" ]]; then
    if [[ "$target" == *.jac ]]; then
      echo "$target"
    fi
    return
  fi
  if [[ -d "$target" ]]; then
    find "$target" -type f \( -name "*_test.jac" -o -name "*.test.jac" \) | sort
  fi
}

declare -a TEST_FILES=()
if (( $# > 0 )); then
  for arg in "$@"; do
    while IFS= read -r f; do
      [[ -n "$f" ]] && TEST_FILES+=("$f")
    done < <(collect_tests "$arg")
  done
else
  while IFS= read -r f; do
    [[ -n "$f" ]] && TEST_FILES+=("$f")
  done < <(collect_tests "lib/jac/tests")
fi

if (( ${#TEST_FILES[@]} == 0 )); then
  echo "PASS: no Jac test files found"
  exit 0
fi

echo "=== jac test harness (lib/jac/tests) ==="
failures=0
for test_file in "${TEST_FILES[@]}"; do
  echo "--- jac test $test_file ---"
  if ! jac test "$test_file"; then
    failures=$((failures + 1))
  fi
  echo ""
done

if (( failures > 0 )); then
  echo "FAIL: jac test harness (${failures}/${#TEST_FILES[@]} file(s) failed)"
  exit 1
fi

echo "PASS: jac test harness (${#TEST_FILES[@]} file(s))"
