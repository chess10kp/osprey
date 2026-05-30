#!/usr/bin/env python3
"""Persistent JSON-RPC worker — stays alive for the entire Jackal session.

Reads JSON-RPC requests (one per line) from stdin, dispatches them to the
same toolchain functions as toolchain_stdio.py, writes JSON-RPC responses
(one per line) to stdout. The worker stays alive until it receives a
"shutdown" method or stdin closes.

This replaces per-call `spawnSync("python3", [toolchain_stdio.py])` with a
single long-lived process, reducing per-call latency from 20-50ms to <2ms.

Protocol:
  Request:  {"jsonrpc": "2.0", "id": <int>, "method": "<op>", "params": {...}}
  Response: {"jsonrpc": "2.0", "id": <int>, "result": <value>}
  Error:    {"jsonrpc": "2.0", "id": <int>, "error": {"code": <int>, "message": "..."}}
"""

from __future__ import annotations

import json
import os
import sys
import traceback

# ── Path setup (same as toolchain_stdio.py) ──────────────────────────────────

_LIB_JAC_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
for _subdir in (
    "jac",
    "config",
    "project",
    "workflow",
    "orchestration",
    "agent",
    "ui",
    "render",
    "core",
    "session",
    "auth",
    "cli",
):
    _pkg = os.path.join(_LIB_JAC_ROOT, _subdir)
    if os.path.isdir(_pkg) and _pkg not in sys.path:
        sys.path.insert(0, _pkg)

# ── Reuse the dispatch table from toolchain_stdio.py ───────────────────────
# Import the _dispatch function directly instead of duplicating all imports.
import importlib.util as _ilu
_stdio_path = os.path.join(_LIB_JAC_ROOT, "bridge", "toolchain_stdio.py")
_mod = _ilu.spec_from_file_location("toolchain_stdio", _stdio_path)
_tsm = _ilu.module_from_spec(_mod)
_mod.loader.exec_module(_tsm)
_dispatch = _tsm._dispatch



# ── Main loop: read JSON-RPC lines from stdin, dispatch, write to stdout ─────

def _write_response(msg_id: int | None, result: object = None, error: dict | None = None) -> None:
    resp: dict = {"jsonrpc": "2.0"}
    if msg_id is not None:
        resp["id"] = msg_id
    if error is not None:
        resp["error"] = error
    else:
        resp["result"] = result
    sys.stdout.write(json.dumps(resp, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def main() -> int:
    # Signal readiness
    _write_response(None, result="ready")

    buf = ""
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue

        try:
            req = json.loads(line)
        except json.JSONDecodeError as e:
            _write_response(None, error={"code": -32700, "message": f"parse error: {e}"})
            continue

        msg_id = req.get("id")
        method = req.get("method")

        if method == "shutdown":
            _write_response(msg_id, result="ok")
            return 0

        if not method:
            _write_response(msg_id, error={"code": -32600, "message": "missing 'method'"})
            continue

        # Convert JSON-RPC method+params to the op format expected by _dispatch
        dispatch_req = {"op": method, **(req.get("params") or {})}

        try:
            payload = _dispatch(dispatch_req)
            _write_response(msg_id, result=payload)
        except Exception as e:
            _write_response(msg_id, error={
                "code": -32603,
                "message": str(e),
                "data": {"trace": traceback.format_exc()},
            })

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
