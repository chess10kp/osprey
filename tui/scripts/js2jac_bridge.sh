#!/usr/bin/env bash
# Fast js2jac bridge harness (Jackal-local copy).
# Converts TS/TSX source on stdin to an emitted-Jac JSON envelope.
# Usage:  echo '<source>' | ./js2jac_bridge.sh [language] [path]
#   language: tsx (default) | ts | jsx | js
#   path:     virtual path label (default: App.tsx)
set -euo pipefail
LANG="${1:-tsx}"; PPATH="${2:-App.tsx}"
DIR="${JS2JAC_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../js2jac" && pwd)}"
SRC="$(cat)"
# 1. JSON-encode the source, build the parse request, parse -> AST envelope
SRC_JSON=$(printf '%s' "$SRC" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
AST_ENV=$(printf '{"protocolVersion":1,"language":"%s","source":%s}' "$LANG" "$SRC_JSON" | bun "$DIR/parser_bridge.mjs" 2>/dev/null)
# 2. build the convert request {protocolVersion, ast, path}, convert -> Jac envelope
CONV_REQ=$(python3 -c 'import json,sys; e=json.loads(sys.stdin.read()); print(json.dumps({"protocolVersion":1,"ast":e["ast"],"path":sys.argv[1]}))' "$PPATH" <<<"$AST_ENV")
printf '%s' "$CONV_REQ" | bun "$DIR/convert_bridge.mjs" | python3 -m json.tool
