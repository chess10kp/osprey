"""Session configuration, model preferences, and MCP attachment."""

import os;
import json;

import from .llm { provider_for, credential_error }
import from .modes { DEV_MODES }
import from .plugin_bridge { PluginBridge, fire_hook, drain_model_requests }
import from .registry { ToolRegistry, register_native }
import from .mcp {
    McpClient,
    create_mcp_client,
    mcp_start,
    mcp_list_tools,
}
import from .session_state {
    history,
    model,
    thinking_level,
    mode,
    plugins,
    _model_prefs,
    _model_prefs_loaded,
}


def set_mode(next_mode: str) -> str {
    if next_mode not in DEV_MODES {
        raise ValueError(
            "invalid mode '" + next_mode
            + "' (expected normal, auto-accept, yolo, plan, or ask)"
        );
    }
    mode = next_mode;
    return mode;
}


"""Return the active dev mode for native UI clients."""
def get_mode() -> str {
    return mode;
}


def _mcp_name_chunk(raw: any) -> str {
    s = str(raw);
    out = "".join([c if (c.isalnum() or c == "_") else "_" for c in s]);
    return out if out else "srv";
}


"""Extract {name: argv} MCP server specs from a parsed .jackal config.
Malformed entries are skipped silently."""
def _mcp_server_specs(cfg: dict[str, any]) -> dict[str, list[str]] {
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


"""Handler factory closing over one client/server/tool triple.

Returns a native-tool handler whose string result mirrors the registry's
resultToString convention (invoke does str(handler(**args))): tool text on
success, ERROR-prefixed strings on transport or MCP-level failures."""
def _make_mcp_handler(client: McpClient, server_name: str, tool_name: str) -> Callable {
    def handle(**args: any) -> str {
        res: dict[str, any] = client.call_tool(tool_name, args);
        if res.get("ok") {
            if res.get("is_error") {
                return (
                    "ERROR: mcp tool " + tool_name + " on " + server_name
                    + " failed: " + str(res.get("result", ""))
                );
            }
            return str(res.get("result", ""));
        }
        return "ERROR: " + str(res.get("error", "mcp call failed"));
    }
    return handle as Callable;
}


"""Spawn + initialize one MCP server, then seed namespaced tools into the
live registry. Runs inside a background flow — never raises."""
def _attach_one_mcp_server(server_name: str, cmd: list[str]) {
    try {
        reg = plugins.reg;
        if reg is None {
            return;
        }
        client = create_mcp_client();
        # Register the client before connecting so dispose can stop it even
        # mid-handshake.
        plugins.mcp_clients[server_name] = client;
        started = mcp_start(client, cmd);
        if not started.get("ok") {
            print(
                "[mcp] server " + server_name + " unavailable, skipping: "
                + str(started.get("error", ""))
            );
            return;
        }
        listed = mcp_list_tools(client);
        if not listed.get("ok") {
            print("[mcp] server " + server_name + " tools/list failed: " + str(listed.get("error", "")));
            return;
        }
        raw_tools: any = listed.get("tools", []);
        if not isinstance(raw_tools, list) {
            return;
        }
        sprefix = _mcp_name_chunk(server_name);
        registered = 0;
        for t in raw_tools {
            if not isinstance(t, dict) {
                continue;
            }
            raw_tool: str = str(t.get("name", ""));
            tname = _mcp_name_chunk(raw_tool);
            if not tname {
                continue;
            }
            schema: any = t.get("inputSchema");
            if not isinstance(schema, dict) or not schema {
                schema = {"type": "object", "properties": {}, "required": []};
            }
            try {
                register_native(
                    reg,
                    "mcp_" + sprefix + "_" + tname,
                    str(t.get("description", "")),
                    schema,
                    _make_mcp_handler(client, server_name, raw_tool),
                );
                registered += 1;
            } except Exception {
            }
        }
        plugins.mcp_tools += registered;
    } except Exception as e {
        print("[mcp] server " + server_name + " attach failed, skipping: " + str(e));
    }
}


"""Parse .jackal mcp config and background-spawn each declared server."""
def _attach_mcp_servers(cfg: dict[str, any]) {
    specs = _mcp_server_specs(cfg);
    for (name, cmd) in specs.items() {
        flow _attach_one_mcp_server(name, cmd);
    }
}



def _model_prefs_path() -> str {
    cwd = plugins.cwd if plugins.cwd else os.getcwd();
    return os.path.join(cwd, ".jackal", "model_prefs.json");
}


"""One-time defensive load of model_prefs.json (missing/corrupt -> {})."""
def _load_model_prefs {
    if _model_prefs_loaded {
        return;
    }
    _model_prefs_loaded = True;
    path = _model_prefs_path();
    if not os.path.isfile(path) {
        return;
    }
    try {
        with open(path, "r") as fh {
            raw = json.load(fh);
        }
        if isinstance(raw, dict) {
            _model_prefs = raw;
        }
    } except (OSError, ValueError) {
    }
}


"""Record the last model overall ("last") and per provider, then persist
to <cwd>/.jackal/model_prefs.json best-effort. Never raises — a preference
write must never break a successful switch."""
def _record_model_pref(name: str) {
    try {
        _load_model_prefs();
        _model_prefs["last"] = name;
        _model_prefs[provider_for(name)] = name;
        prefs_dir = os.path.join(
            plugins.cwd if plugins.cwd else os.getcwd(), ".jackal"
        );
        os.makedirs(prefs_dir, exist_ok=True);
        path = os.path.join(prefs_dir, "model_prefs.json");
        with open(path, "w") as fh {
            json.dump(_model_prefs, fh, indent=2, sort_keys=True);
            fh.write("\n");
        }
    } except Exception {
    }
}


"""Snapshot of persisted last-model preferences ("last" + provider keys).
For the TUI /model picker to preselect per-provider defaults."""
def model_preferences() -> dict[str, any] {
    _load_model_prefs();
    return dict(_model_prefs);
}


"""Switch the active model. Validates credentials fx-style BEFORE applying:
a model whose provider key is missing is refused and the actionable error
text is returned instead of the model name (callers render the returned
string directly). On success fires Pi's model_select hook best-effort so
listeners see every change regardless of source (/model command or an
extension's pi.setModel applied via _apply_pending_model_requests) and
records the per-provider/overall last-model preference."""
def set_model(name: str) -> str {
    err = credential_error(name);
    if err {
        return err;
    }
    model = name;
    _record_model_pref(name);
    b = plugins.bridge;
    if b is not None {
        try {
            fire_hook(b as PluginBridge, "model_select", {"model": name});
        } except Exception {
        }
    }
    return model;
}


"""Set the reasoning-effort level used for subsequent turns (empty = off).
The transport layer maps it to the request body's reasoning.effort. Fires
Pi's thinking_level_select hook best-effort, mirroring set_model."""
def set_thinking_level(level: str) -> str {
    thinking_level = level;
    b = plugins.bridge;
    if b is not None {
        try {
            fire_hook(b as PluginBridge, "thinking_level_select", {"level": level});
        } except Exception {
        }
    }
    return thinking_level;
}


def clear_history {
    history.clear();
}





"""Apply extension-issued model and thinking-level requests."""
def _apply_pending_model_requests() {
    b = plugins.bridge;
    if b is None {
        return;
    }
    req: dict[str, any] = drain_model_requests(b as PluginBridge);
    m = str(req.get("model", ""));
    lv = str(req.get("thinking_level", ""));
    if m and m != model {
        set_model(m);
    }
    if lv and lv != thinking_level {
        set_thinking_level(lv);
    }
}
