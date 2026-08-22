#!/usr/bin/env bash
# Resolve Node binary for the Jackal plugin sidecar (P5).
# Prefer JACKAL_NODE_BIN, then pinned plugin_host/node/bin/node, else PATH.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST_DIR="${ROOT}/app/plugin_host"

if [[ -n "${JACKAL_NODE_BIN:-}" ]]; then
  echo "${JACKAL_NODE_BIN}"
  exit 0
fi
if [[ -x "${HOST_DIR}/node/bin/node" ]]; then
  echo "${HOST_DIR}/node/bin/node"
  exit 0
fi
if [[ -x "${HOST_DIR}/.node-bin" ]]; then
  echo "${HOST_DIR}/.node-bin"
  exit 0
fi
if command -v node >/dev/null 2>&1; then
  command -v node
  exit 0
fi
echo "node not found — set JACKAL_NODE_BIN or install a pinned sidecar under app/plugin_host/node/" >&2
exit 1
