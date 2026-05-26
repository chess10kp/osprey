"""Session-scoped tool permissions — pattern matching and approval evaluation."""

from __future__ import annotations

import fnmatch
import json
import re
import time
from pathlib import Path

# ---------------------------------------------------------------------------
# Pattern matching
# ---------------------------------------------------------------------------

PATTERN_TYPES = ("glob", "regex", "exact", "prefix")


def match_pattern(resource: str, pattern: str, ptype: str = "glob") -> bool:
    if pattern == "*":
        return True
    if not resource:
        return False

    if ptype == "exact":
        return resource == pattern
    if ptype == "prefix":
        return resource.startswith(pattern)
    if ptype == "regex":
        try:
            return bool(re.search(pattern, resource))
        except re.error:
            return False

    # glob (default) — case-insensitive fnmatch
    return fnmatch.fnmatch(resource.lower(), pattern.lower())


def _extract_resource(tool_name: str, params: dict) -> str:
    if tool_name in ("bash", "jac_cli"):
        cmd = params.get("command")
        if isinstance(cmd, str):
            return cmd
        args = params.get("args")
        if isinstance(args, list):
            return "jac " + " ".join(str(a) for a in args)
        return ""

    if tool_name in ("write", "edit"):
        p = params.get("path")
        return p if isinstance(p, str) else ""

    if tool_name == "mcp":
        server = params.get("server_name", "")
        tool = params.get("tool_name", "")
        return f"{server}:{tool}"

    return ""


# ---------------------------------------------------------------------------
# Pattern evaluation
# ---------------------------------------------------------------------------

def evaluate_permission_patterns(
    patterns: list[dict],
    tool_name: str,
    resource: str,
) -> str | None:
    """Return "allow", "deny", or None."""
    allow_match = False
    for p in patterns:
        ptool = p.get("tool", "")
        if ptool != "*" and ptool != tool_name:
            continue
        pat = p.get("pattern", "")
        ptype = p.get("type", "glob")
        if not match_pattern(resource, pat, ptype):
            continue
        if p.get("action") == "deny":
            return "deny"
        allow_match = True
    return "allow" if allow_match else None


# ---------------------------------------------------------------------------
# Always-allow loading
# ---------------------------------------------------------------------------

def load_always_allow_tools(cwd: str, project_config: dict | None = None) -> list[str]:
    allowed: set[str] = set()

    cfg = project_config or {}
    for name in (cfg.get("alwaysAllow") or []):
        if isinstance(name, str) and name.strip():
            allowed.add(name.strip())

    mcp_path = Path(cwd) / "pi" / "mcp.json"
    if mcp_path.is_file():
        try:
            data = json.loads(mcp_path.read_text(encoding="utf-8"))
            for server in (data.get("mcpServers") or {}).values():
                for name in (server.get("alwaysAllow") or []):
                    if isinstance(name, str) and name.strip():
                        allowed.add(name.strip())
        except (json.JSONDecodeError, OSError):
            pass

    return sorted(allowed)


# ---------------------------------------------------------------------------
# Permission patterns from config
# ---------------------------------------------------------------------------

def load_permission_patterns(project_config: dict | None = None) -> list[dict]:
    cfg = project_config or {}
    patterns: list[dict] = []

    for entry in (cfg.get("permissionPatterns") or []):
        if (
            isinstance(entry, dict)
            and isinstance(entry.get("tool"), str)
            and isinstance(entry.get("pattern"), str)
        ):
            patterns.append({
                "tool": entry["tool"],
                "pattern": entry["pattern"],
                "type": entry.get("type", "glob"),
                "action": entry.get("action", "allow"),
            })

    return patterns


# ---------------------------------------------------------------------------
# Needs-approval check
# ---------------------------------------------------------------------------

def needs_tool_approval(
    mode: str,
    tool_name: str,
    params: dict,
    *,
    session_granted: list[str] | None = None,
    session_pattern_grants: list[dict] | None = None,
    always_allow: list[str] | None = None,
    permission_patterns: list[dict] | None = None,
    resource: str | None = None,
) -> bool:
    """Pure logic: return True when tool should block for user confirmation."""
    res = resource or _extract_resource(tool_name, params)

    # 1. Permission patterns (deny → True, allow → False)
    if permission_patterns:
        result = evaluate_permission_patterns(permission_patterns, tool_name, res)
        if result == "deny":
            return True
        if result == "allow":
            return False

    # 2. Always-allow
    if always_allow and tool_name in always_allow:
        return False

    # 3. Session exact grants
    if session_granted and tool_name in session_granted:
        return False

    # 4. Session pattern grants
    if session_pattern_grants:
        for pg in session_pattern_grants:
            pgtool = pg.get("tool", "")
            if pgtool != "*" and pgtool != tool_name:
                continue
            if match_pattern(res, pg.get("pattern", ""), pg.get("type", "glob")):
                return False

    # 5. Dev mode policy
    from _dev_mode_toolchain import should_auto_approve  # noqa: C0415

    return not should_auto_approve(mode, tool_name, params)
