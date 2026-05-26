"""Phase 0 feasibility spike — Jac subprocess + Node npm bridge for pi-agent-core."""

::py::
import os
import subprocess
import sys as _sys

_jac_pkg = os.path.join(os.getcwd(), "lib", "jac", "jac")
if _jac_pkg not in _sys.path:
    _sys.path.insert(0, _jac_pkg)

from _cli_toolchain import find_jac_binary, parse_jac_check_output
from _npm_bridge import run_npm_agent_spike


def run_spike() -> int:
    print("=== Jackal Phase 0 Feasibility Spike ===\n")

    jac_bin = find_jac_binary()
    if jac_bin:
        print(f"✓ jac binary: {jac_bin}")
        ver = subprocess.run(
            [jac_bin, "--version"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        first_line = (ver.stdout or "").strip().split("\n")[0]
        print(f"✓ jac --version: {first_line}")
    else:
        print("✗ jac binary not found on PATH")

    sample = "src/foo.jac:10:5: error: undefined name 'x'"
    diags = parse_jac_check_output(sample, "")
    if diags and diags[0]["file"] == "src/foo.jac":
        print(f"✓ parse_jac_check_output: {len(diags)} diagnostic(s)")
    else:
        print("✗ parse_jac_check_output failed")

    npm_result = run_npm_agent_spike()
    npm_ok = npm_result.get("ok")
    if npm_ok:
        print("✓ npm interop (pi-agent-core via Node bridge)")
        for check in npm_result.get("checks", []):
            name = check.get("name", "?")
            detail = check.get("detail", "")
            mark = "✓" if check.get("ok") else "✗"
            print(f"  {mark} {name}: {detail}")
        turn = npm_result.get("turn") or {}
        if turn.get("ok"):
            events = len(turn.get("eventTypes") or [])
            text = turn.get("responseText", "")
            print(f"✓ headless agent turn (prompt → agent_end, {events} events, text={text!r})")
        else:
            npm_ok = False
            print(f"✗ headless agent turn: {turn.get('error', 'failed')}")
    else:
        print(f"✗ npm interop: {npm_result.get('error', 'failed')}")
        for check in npm_result.get("checks", []):
            if not check.get("ok"):
                print(f"  ✗ {check.get('name')}: {check.get('detail')}")

    print("\n=== Phase 0 Spike Complete ===")
    if jac_bin and npm_ok:
        print("Gate 0: GO — Jac toolchain + one headless agent turn via npm bridge.")
        print("Note: pi-agent-core runs via Node until in-process Jac/npm interop lands.")
        return 0
    print("Gate 0: NO-GO — see failures above.")
    return 1
::py::

with entry {
    code = run_spike();
    if code != 0 {
        raise SystemExit(code);
    }
}
