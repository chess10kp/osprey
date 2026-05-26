"""Jackal Jac core entry — toolchain `--check` (Phase 0–1 migration path)."""

import sys;

::py::
import os
import sys as _sys

_jac_pkg = os.path.join(os.getcwd(), "lib", "jac", "jac")
if _jac_pkg not in _sys.path:
    _sys.path.insert(0, _jac_pkg)

import shutil

from _doctor_toolchain import run_jac_doctor
from _cli_toolchain import run_jac_check
from _npm_bridge import run_npm_agent_spike, print_npm_agent_check


def run_agent_loop_check(cwd: str) -> int:
    """pi-agent-core headless turn via Node bridge (no API keys; faux provider)."""
    if not shutil.which("node"):
        print("FAIL: node not on PATH (required for pi-agent-core bridge)")
        return 1
    if not os.path.isdir(os.path.join(cwd, "node_modules")):
        print("FAIL: node_modules missing — run npm ci in repo root first")
        return 1
    print("=== npm agent loop (pi-agent-core bridge) ===")
    result = run_npm_agent_spike(cwd)
    return print_npm_agent_check(result)


def run_toolchain_check(cwd: str) -> int:
    report = run_jac_doctor(cwd)
    print(report["summary"])
    print("")

    if not report.get("jacBinary"):
        print("FAIL: jac binary missing")
        return 1

    check = run_jac_check(
        cwd,
        ["lib/jac/jac", "lib/jac/project", "lib/jac/main.jac", "lib/jac/spike"],
    )
    exit_code = check.get("exitCode", 1)
    diagnostics = check.get("diagnostics", [])
    if exit_code != 0 and not diagnostics:
        err = check.get("exitError", "jac check lib/jac failed")
        print(f"FAIL: {err}")
        return 1

    errors = [d for d in diagnostics if d.get("severity") == "error"]
    if errors:
        print(f"FAIL: {len(errors)} jac check error(s) in lib/jac:")
        for d in errors[:10]:
            print(f"  {d['file']}:{d['line']}: {d['message']}")
        return 1

    print("PASS: lib/jac toolchain check")
    print("")
    agent_code = run_agent_loop_check(cwd)
    if agent_code != 0:
        return agent_code
    print("")
    print("PASS: lib/jac full check (toolchain + npm agent loop)")
    return 0


def _parse_argv(argv: list) -> dict:
    args = {"check": False, "cwd": os.getcwd()}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("--check", "-c"):
            args["check"] = True
        elif a == "--cwd" and i + 1 < len(argv):
            args["cwd"] = argv[i + 1]
            i += 1
        i += 1
    return args
::py::

with entry {
    parsed = _parse_argv(list(sys.argv[1:]));
    if parsed["check"] {
        code = run_toolchain_check(parsed["cwd"]);
        sys.exit(int(code));
    }
    print("Jackal Jac core — usage:");
    print("  jac run lib/jac/main.jac -- --check");
    print("  jac run lib/jac/spike/agent_spike.jac");
}
