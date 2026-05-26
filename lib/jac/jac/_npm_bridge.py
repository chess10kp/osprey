"""Node subprocess bridge for pi-agent-core (lib/jac/spike/npm_agent_spike.mjs)."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from typing import Any

_SPIKE_SCRIPT = os.path.join("lib", "jac", "spike", "npm_agent_spike.mjs")


def run_npm_agent_spike(cwd: str | None = None) -> dict[str, Any]:
    """Run npm_agent_spike.mjs; return parsed JSON (ok, checks, turn, error)."""
    root = cwd or os.getcwd()
    script = os.path.join(root, _SPIKE_SCRIPT)
    node_cmd = shutil.which("node") or "node"
    if not os.path.isfile(script):
        return {
            "ok": False,
            "error": f"spike script not found: {script}",
            "checks": [],
        }

    proc = subprocess.run(
        [node_cmd, script],
        cwd=root,
        capture_output=True,
        text=True,
        timeout=60,
    )
    stdout = (proc.stdout or "").strip()
    stderr = (proc.stderr or "").strip()
    if proc.returncode != 0 and not stdout:
        return {
            "ok": False,
            "error": stderr or f"npm spike exit {proc.returncode}",
            "checks": [],
        }
    try:
        return json.loads(stdout)
    except json.JSONDecodeError:
        return {
            "ok": False,
            "error": f"invalid JSON from npm spike: {stdout[:200]}",
            "checks": [],
        }


def print_npm_agent_check(result: dict[str, Any]) -> int:
    """Print npm bridge results; return 0 on success."""
    if result.get("ok"):
        print("PASS: npm agent loop (pi-agent-core via Node bridge)")
        for check in result.get("checks", []):
            name = check.get("name", "?")
            detail = check.get("detail", "")
            mark = "✓" if check.get("ok") else "✗"
            print(f"  {mark} {name}: {detail}")
        turn = result.get("turn") or {}
        if turn.get("ok"):
            events = len(turn.get("eventTypes") or [])
            text = turn.get("responseText", "")
            print(
                f"  ✓ headless turn: agent_end ({events} events, text={text!r})"
            )
        return 0

    print(f"FAIL: npm agent loop — {result.get('error', 'failed')}")
    for check in result.get("checks", []):
        if not check.get("ok"):
            print(f"  ✗ {check.get('name')}: {check.get('detail')}")
    turn = result.get("turn") or {}
    if turn and not turn.get("ok"):
        print(f"  ✗ headless turn: {turn.get('error', 'failed')}")
    return 1
