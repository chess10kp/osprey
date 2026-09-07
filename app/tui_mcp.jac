"""MCP status picker data."""
import os;
import from tui_state { LiveShell }
import from tui_picker_base { _open_picker }
import from agent.compaction { load_project_config }
import from agent.session { plugins }

"""MCP server specs from a parsed .jackal config — local copy of
agent.session's _mcp_server_specs shape ({name: argv}). Inlined because
underscore-prefixed imports from agent.session did not bind at runtime
(NameError swallowed by callers); keep in sync with session.jac."""
def _local_mcp_server_specs(cfg: dict) -> dict[str, list[str]] {
    out: dict[str, list[str]] = {};
    raw: any = cfg.get("mcp") if isinstance(cfg, dict) else None;
    if not isinstance(raw, dict) {
        return out;
    }
    servers: any = raw.get("servers");
    if not isinstance(servers, dict) {
        return out;
    }
    for (name, ent) in servers.items() {
        if not isinstance(ent, dict) or not str(name) {
            continue;
        }
        cmd: any = ent.get("command");
        if isinstance(cmd, str) {
            cmd = [cmd];
        }
        if not isinstance(cmd, list) or not cmd {
            continue;
        }
        parts: list[str] = [str(c) for c in cmd];
        extra: any = ent.get("args");
        if isinstance(extra, list) {
            parts.extend([str(a) for a in extra]);
        }
        out[str(name)] = parts;
    }
    return out;
}


"""MCP STATUS overlay rows: one line per server declared in the walk-up
.jackal config ("mcp": {"servers": …}), plus any runtime-attached clients
not present in config. Connection state is honest: clients live in
agent.session plugins.mcp_clients only after a successful spawn+handshake,
so a configured-but-absent client is reported "not connected", and a
present-but-uninitialized one as "spawn failed". Pure over (cwd, clients)
— replicated in tui_overlays.test.jac (keep in sync)."""
def _mcp_status_entries(cwd: str, clients: dict) -> dict {
    specs: dict[str, list[str]] = {};
    try {
        cfg: dict = load_project_config(cwd);
        parsed: dict[str, list[str]] = _local_mcp_server_specs(cfg);
        specs = parsed;
    } except Exception {
        specs = {};
    }
    rows: list[str] = [];
    ids: list[str] = [];
    declared: set[str] = set();
    for name in sorted(specs) {
        sname: str = str(name);
        declared.add(sname);
        cmd_label: str = " ".join(specs[name]);
        client: any = clients.get(sname);
        if client is not None and client.initialized is True {
            rows.append(sname + " — connected · " + cmd_label);
        } elif client is not None {
            rows.append(sname + " — spawn failed · " + cmd_label);
        } else {
            rows.append(sname + " — configured · not connected · " + cmd_label);
        }
        ids.append("__header__");
    }
    for cname in sorted(clients) {
        if str(cname) in declared {
            continue;
        }
        rows.append(str(cname) + " — attached (not in .jackal config)");
        ids.append("__header__");
    }
    if not rows {
        rows.append("no mcp servers configured (.jackal: \"mcp\": {\"servers\": …})");
        ids.append("__header__");
    }
    return {"rows": rows, "ids": ids};
}


"""Open the read-only MCP status overlay; every row is furniture, so enter
is a no-op and esc dismisses."""
def _open_mcp_picker(app: LiveShell) -> str {
    clients_arg: dict = {};
    raw_clients: any = plugins.mcp_clients;
    if isinstance(raw_clients, dict) {
        clients_arg = raw_clients;
    }
    entries = _mcp_status_entries(os.getcwd(), clients_arg);
    opened = _open_picker(app, "MCP STATUS", entries["rows"], entries["ids"]);
    if not opened {
        return "picker unavailable (overlay busy)";
    }
    return "";
}
