"""Slash-command and @file autocomplete suggestions."""

from __future__ import annotations

import re

COMMANDS: list[dict] = [
    {"slash": "/help", "description": "toggle help panel"},
    {"slash": "/login", "description": "start auth flow"},
    {"slash": "/logout", "description": "logout provider"},
    {"slash": "/model", "description": "open model picker or set"},
    {"slash": "/abort", "description": "cancel active run"},
    {"slash": "/clear", "description": "new session"},
    {"slash": "/new", "description": "new session"},
    {"slash": "/compact", "description": "compact context"},
    {"slash": "/usage", "description": "context utilization"},
    {"slash": "/resume", "description": "load prior session"},
    {"slash": "/rename", "description": "rename current session"},
    {"slash": "/export", "description": "export session to file"},
    {"slash": "/checkpoint", "description": "snapshot files + chat"},
    {"slash": "/diff", "description": "terminal diff editor (git)"},
    {"slash": "/tasks", "description": "task list"},
    {"slash": "/mcp", "description": "MCP connection status"},
    {"slash": "/osp", "description": "OSP graph design"},
    {"slash": "/plan", "description": "generate implementation plan"},
    {"slash": "/agents", "description": "list subagents"},
    {"slash": "/commands", "description": "list custom commands"},
    {"slash": "/skills", "description": "list agent skills"},
    {"slash": "/init", "description": "generate AGENTS.md"},
    {"slash": "/jac-check", "description": "run jac check"},
    {"slash": "/jac-doctor", "description": "environment diagnostics"},
    {"slash": "/jac-test", "description": "run jac test"},
    {"slash": "/jac-format", "description": "format .jac files"},
    {"slash": "/jac explain", "description": "explain file/walker/error/graph"},
    {"slash": "/jac convert-python", "description": "convert Python to Jac"},
    {"slash": "/jac review-idioms", "description": "review Jac idioms"},
    {"slash": "/jac create", "description": "run jac create template"},
    {"slash": "/fix", "description": "jac check/fix loop"},
    {"slash": "/create", "description": "list jac templates"},
    {"slash": "/explorer", "description": "multi-select @file context"},
    {"slash": "/context-max", "description": "set/show max context tokens"},
    {"slash": "/jac diagram-to-model", "description": "diagram → OSP model"},
    {"slash": "/refactor", "description": "refactor code"},
    {"slash": "/exit", "description": "quit"},
    {"slash": "/cancel", "description": "cancel auth flow"},
]


def _rank(input_text: str, value: str) -> int:
    i = input_text.lower()
    v = value.lower()
    if not i:
        return 0
    if v == i:
        return 100
    if v.startswith(i):
        return 80
    if i in v:
        return 50
    return -1


def sort_and_map(input_text: str, values: list[str]) -> list[dict]:
    seen: set[str] = set()
    scored: list[tuple[dict, int]] = []
    for v in values:
        if v in seen:
            continue
        seen.add(v)
        s = _rank(input_text, v)
        if s >= 0:
            scored.append(({"label": v, "value": v}, s))

    scored.sort(key=lambda x: (-x[1], x[0]["value"]))
    return [item for item, _ in scored[:8]]


def sort_and_map_commands(input_text: str, commands: list[dict] | None = None) -> list[dict]:
    cmds = commands or COMMANDS
    scored: list[tuple[dict, int]] = []
    for c in cmds:
        s = _rank(input_text, c["slash"])
        if s >= 0:
            label = f'{c["slash"]}  {c["description"]}'
            scored.append(({"label": label, "value": c["slash"]}, s))

    scored.sort(key=lambda x: (-x[1], x[0]["value"]))
    return [item for item, _ in scored[:8]]


def _rank_file(query: str, file_path: str) -> int:
    q = query.lower()
    p = file_path.lower()
    name = file_path.split("/")[-1] if "/" in file_path else file_path
    n = name.lower()

    if not q:
        return 50
    if p == q:
        return 1000
    if n == q:
        return 900
    if p.endswith(q):
        return 850
    if n.startswith(q):
        return 800
    if p.startswith(q):
        return 750
    if q in n:
        return 700
    if q in p:
        return 600

    # fuzzy
    pi = 0
    qi = 0
    while pi < len(p) and qi < len(q):
        if p[pi] == q[qi]:
            qi += 1
        pi += 1
    return 500 if qi == len(q) else -1


def get_file_suggestions(
    input_text: str,
    file_paths: list[str],
    cursor_position: int | None = None,
) -> list[dict]:
    """Get @file autocomplete suggestions."""
    # Parse current @mention at cursor
    from _file_mention_parser_toolchain import get_current_file_mention as _gcfm  # noqa: C0415

    mention = _gcfm(input_text, cursor_position)
    if not mention:
        return []

    query = mention["mention"]
    start = mention["start"]
    end = mention["end"]
    range_suffix = mention.get("rangeSuffix", "")

    seen: set[str] = set()
    scored: list[tuple[dict, int]] = []
    for fp in file_paths:
        if fp in seen:
            continue
        seen.add(fp)
        s = _rank_file(query, fp)
        if s >= 0:
            scored.append(
                (
                    {
                        "label": fp,
                        "value": input_text[:start] + "@" + fp + range_suffix + input_text[end:],
                    },
                    s,
                )
            )

    scored.sort(key=lambda x: (-x[1], x[0]["label"]))
    return [item for item, _ in scored[:8]]


def get_suggestions(
    input_text: str,
    auth_step_kind: str = "",
    providers: list[str] | None = None,
    models: list[str] | None = None,
    auth_options: list[str] | None = None,
    file_paths: list[str] | None = None,
    custom_commands: list[str] | None = None,
    cursor_position: int | None = None,
) -> list[dict]:
    """Main entry point for autocomplete."""
    providers = providers or []
    models = models or []
    auth_options = auth_options or []
    file_paths = file_paths or []
    custom_commands = custom_commands or []

    # File suggestions first
    file_suggs = get_file_suggestions(input_text, file_paths, cursor_position)
    if file_suggs:
        return file_suggs

    trimmed = input_text.strip()

    if auth_step_kind == "select":
        return sort_and_map(trimmed, auth_options)

    if auth_step_kind == "provider_picker":
        return sort_and_map(trimmed, providers)

    if auth_step_kind == "model_picker":
        return sort_and_map(trimmed, models)

    if not trimmed.startswith("/"):
        return []

    if trimmed.startswith("/login "):
        q = trimmed[len("/login "):]
        return [
            {**s, "value": f"/login {s['value']}"}
            for s in sort_and_map(q, providers)
        ]

    if trimmed.startswith("/logout "):
        q = trimmed[len("/logout "):]
        return [
            {**s, "value": f"/logout {s['value']}"}
            for s in sort_and_map(q, providers)
        ]

    if trimmed.startswith("/model "):
        q = trimmed[len("/model "):]
        return [
            {**s, "value": f"/model {s['value']}"}
            for s in sort_and_map(q, models)
        ]

    if custom_commands:
        custom_matches = sort_and_map(trimmed, custom_commands)
        if custom_matches:
            return custom_matches

    return sort_and_map_commands(trimmed)
