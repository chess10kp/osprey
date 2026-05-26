"""Jac CLI helpers — shared by cli.jac and the TypeScript toolchain bridge."""

from __future__ import annotations

import re
import shutil
import subprocess

_ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


def parse_jac_check_output(stdout: str, stderr: str) -> list:
    diagnostics = []
    combined = stdout + "\n" + stderr
    lines = combined.split("\n")
    pending = None

    for raw in lines:
        stripped = _ANSI_RE.sub("", raw).strip()
        if not stripped:
            continue

        single = re.match(
            r"^(.+?):(\d+):(\d+):\s+(error|warning|info):\s+(.*)$",
            stripped,
            re.IGNORECASE,
        )
        if single:
            diagnostics.append(
                {
                    "file": single.group(1),
                    "line": int(single.group(2)),
                    "column": int(single.group(3)),
                    "severity": single.group(4).lower(),
                    "message": single.group(5),
                    "raw": stripped,
                }
            )
            pending = None
            continue

        header = re.match(
            r"^(?:[✖✗❌]\s*)?(Error|Warning|Info|Note)"
            r"(?::\s*(?:(error|warning|info)\[([A-Z0-9]+)\])?)?:?\s*(.*)$",
            stripped,
            re.IGNORECASE,
        )
        if header and re.match(
            r"^[✖✗❌]?\s*(Error|Warning|Info|Note)",
            stripped,
            re.IGNORECASE,
        ):
            sev = (header.group(2) or header.group(1) or "error").lower()
            pending = {
                "severity": sev,
                "code": header.group(3) or "",
                "message": (header.group(4) or "").strip(),
                "raw": stripped,
            }
            continue

        loc = re.match(r"^-->\s*(.+?):(\d+):(\d+)\s*$", stripped)
        if loc and pending:
            diagnostics.append(
                {
                    "file": loc.group(1),
                    "line": int(loc.group(2)),
                    "column": int(loc.group(3)),
                    "severity": pending["severity"],
                    "code": pending.get("code") or "",
                    "message": pending["message"],
                    "raw": pending["raw"],
                }
            )
            pending = None

    return diagnostics


def fingerprint_errors(errors: list) -> str:
    parts = [
        f"{d['file']}:{d['line']}:{d.get('column', 0)}:{d.get('code', '')}:{d['message']}"
        for d in errors
    ]
    return "\n".join(sorted(parts))


def find_jac_binary() -> str:
    for cmd in ("jac", "jaclang"):
        if shutil.which(cmd):
            return cmd
    return ""


def format_diagnostics(diagnostics: list) -> str:
    lines = []
    for d in diagnostics:
        col = f":{d['column']}" if d.get("column") else ""
        code = f" [{d['code']}]" if d.get("code") else ""
        lines.append(
            f"- {d['file']}:{d['line']}{col} [{d['severity']}]{code} {d['message']}"
        )
    return "\n".join(lines)


def run_jac_command(
    cmd: list, cwd: str, timeout_ms: int = 120000, parse_diagnostics: bool = True
) -> dict:
    jac_bin = find_jac_binary()
    if not jac_bin:
        raise ValueError("jac binary not found. Install with: pip install jaclang")
    if not cmd:
        raise ValueError("run_jac_command requires at least one subcommand arg")

    timeout_s = max(1, timeout_ms // 1000)
    should_parse = parse_diagnostics and cmd[0] == "check"

    try:
        proc = subprocess.run(
            [jac_bin, *cmd],
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=timeout_s,
        )
        stdout = proc.stdout or ""
        stderr = proc.stderr or ""
        raw = stdout + stderr
        diags = parse_jac_check_output(stdout, stderr) if should_parse else []
        return {
            "stdout": stdout,
            "stderr": stderr,
            "rawOutput": raw,
            "exitCode": proc.returncode,
            "diagnostics": diags,
        }
    except subprocess.TimeoutExpired as e:
        stdout = e.stdout or "" if e.stdout else ""
        stderr = e.stderr or "" if e.stderr else ""
        raw = stdout + stderr
        diags = parse_jac_check_output(stdout, stderr) if should_parse else []
        return {
            "stdout": stdout,
            "stderr": stderr,
            "rawOutput": raw or "jac command timed out",
            "exitCode": 1,
            "diagnostics": diags,
        }
    except Exception as e:
        msg = str(e)
        if not msg.strip():
            raise
        return {
            "stdout": "",
            "stderr": msg,
            "rawOutput": msg,
            "exitCode": 1,
            "diagnostics": [],
        }


def run_jac_check(cwd: str, files: list | None = None) -> dict:
    targets = files if files else ["."]
    result = run_jac_command(["check", *targets], cwd, parse_diagnostics=True)
    exit_error = ""
    if not result["diagnostics"] and result["exitCode"] != 0:
        exit_error = result["stderr"].strip() or "jac check failed"
    return {
        "diagnostics": result["diagnostics"],
        "rawOutput": result["rawOutput"],
        "exitCode": result["exitCode"],
        "exitError": exit_error,
    }


def run_jac_format(cwd: str, files: list) -> dict:
    if not files:
        return {"changed": False, "rawOutput": "", "exitCode": 0}
    result = run_jac_command(["format", *files], cwd, parse_diagnostics=False)
    combined = result["rawOutput"].strip()
    changed = "changed" in combined and "FAILURES" not in combined
    return {
        "changed": changed,
        "rawOutput": combined,
        "exitCode": result["exitCode"],
    }


def run_jac_test(cwd: str, files: list | None = None) -> dict:
    args = ["test"]
    if files:
        args.extend(files)
    result = run_jac_command(args, cwd, timeout_ms=300000, parse_diagnostics=True)
    errors = [d for d in result["diagnostics"] if d.get("severity") == "error"]
    passed = result["exitCode"] == 0 and not errors
    return {
        "passed": passed,
        "rawOutput": result["rawOutput"],
        "exitCode": result["exitCode"],
        "diagnostics": result["diagnostics"],
    }


def run_jac_run_file(
    cwd: str, file: str, extra_args: list | None = None, timeout_ms: int = 60000
) -> dict:
    args = ["run", file]
    if extra_args:
        args.extend(extra_args)
    result = run_jac_command(args, cwd, timeout_ms=timeout_ms, parse_diagnostics=False)
    err = ""
    if result["exitCode"] != 0:
        err = result["stderr"].strip() or "jac run failed"
    return {
        "stdout": result["stdout"],
        "stderr": result["stderr"],
        "exitCode": result["exitCode"],
        "error": err,
    }
