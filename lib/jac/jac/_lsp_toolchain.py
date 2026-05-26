"""LSP config resolution — shared by lsp_service.jac and the TypeScript bridge."""

from __future__ import annotations

import json
from pathlib import Path

from _cli_toolchain import find_jac_binary

DEFAULT_AUTO_START = ["jac"]
DEFAULT_JAC_SERVER = {"command": "jac", "args": ["lsp"]}


def find_pi_lsp_config_path(cwd: str) -> str:
    cur = Path(cwd).resolve()
    while True:
        candidate = cur / ".pi-lsp.json"
        if candidate.is_file():
            return str(candidate)
        parent = cur.parent
        if parent == cur:
            return ""
        cur = parent


def load_pi_lsp_config(cwd: str) -> dict | None:
    path = find_pi_lsp_config_path(cwd)
    if not path:
        return None
    try:
        parsed = json.loads(Path(path).read_text(encoding="utf-8"))
        return parsed if isinstance(parsed, dict) else None
    except (OSError, json.JSONDecodeError):
        return None


def resolve_lsp_config(cwd: str, project_config: dict | None = None) -> dict:
    cfg = project_config or {}
    pi_lsp = load_pi_lsp_config(cwd) or {}
    enabled = cfg.get("lsp") is not False and pi_lsp.get("enabled") is not False
    auto_start = (
        pi_lsp["autoStart"]
        if "autoStart" in pi_lsp
        else list(DEFAULT_AUTO_START)
    )

    jac_bin = find_jac_binary() or DEFAULT_JAC_SERVER["command"]
    servers: dict = {
        "jac": {
            "command": jac_bin,
            "args": list(DEFAULT_JAC_SERVER["args"]),
        }
    }

    pi_servers = pi_lsp.get("servers")
    if isinstance(pi_servers, dict):
        for lang, conf in pi_servers.items():
            if not isinstance(conf, dict):
                continue
            cmd = conf.get("command", "jac")
            resolved_cmd = jac_bin if cmd == "jac" else cmd
            entry: dict = {
                "command": resolved_cmd,
                "args": list(conf.get("args") or []),
            }
            env = conf.get("env")
            if isinstance(env, dict):
                entry["env"] = env
            servers[lang] = entry

    return {"enabled": enabled, "autoStart": auto_start, "servers": servers}
