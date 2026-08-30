"""Jackal agent session — owned ReAct loop + StreamEvent-style rendering.

Owns the plugin bridge and parallel Node sidecar warm (D21). History is a
caller-owned list of OpenAI-shape message dicts. Model transport is rebuilt
from the model name on each turn so /model swaps are immediate.
"""

import sys;
import os;
import json;
import time;


import from .llm {
    Transport,
    react_loop,
    make_transport,
    make_ext_transport,
    TurnCancel,
    provider_for,
    credential_error,
}
import from .compaction {
    load_project_config,
    resolve_auto_compact_config,
    compute_context_usage,
    should_auto_compact,
    build_mechanical_summary,
    summarize_for_compaction,
}
import from .tools { default_registry }
import from .system { SYSTEM_PROMPT }
import from .modes { DEV_MODES, system_prompt_for_mode }
import from .plugin_bridge {
    PluginBridge,
    create_bridge,
    dispose_bridge,
    host_status,
    ensure_node_host,
    load_extension_path,
    invoke_command,
    invoke_shortcut,
    fire_user_bash,
    fire_hook,
    transform_markdown,
    drain_extension_traffic,
    agent_start_gate,
    input_gate,
    render_extension_block,
    list_shortcuts,
    list_labels,
    drain_model_requests,
    fire_project_trust,
}
import from .registry { ToolRegistry, register_native, get_tool }
import from .mcp {
    McpClient,
    create_mcp_client,
    mcp_start,
    mcp_list_tools,
    mcp_stop,
}
import from .extensions {
    ExtensionDecl,
    ExtensionStatus,
    load_extension_decls,
    node_sidecar_decls,
    extensions_label,
    resolve_decl_path,
    decl_from_dict,
}

import from .sessions {
    save_session,
    list_sessions,
    latest_session_id,
    get_session_record,
    export_session,
    new_session_id,
    is_valid_session_id,
}


"""Mutable plugin/session control-plane state (avoid glob reassignment traps)."""
obj SessionPlugins {
    has session_id: str = "session",
        cwd: str = "",
        bridge: PluginBridge | None = None,
        reg: ToolRegistry | None = None,
        decls: list[any] = [],
        loaded: int = 0,
        total: int = 0,
        ready: bool = True,
        phase: str = "idle",
        detail: str = "",
        t_interactive: float = 0.0,
        t_ext_ready: float = 0.0,
        prompt_queue: list[str] = [],
        warm_future: any = None,
        wait_budget_s: float = 5.0,
        commands: dict[str, any] = {},
        interactive_ui: bool = False,
        active_cancel: any = None,
        mcp_clients: dict[str, McpClient] = {},
        mcp_tools: int = 0;
}


glob history: list[dict[str, any]] = [],
     show_stats: bool = True,
     model: str = os.environ.get("JACKAL_MODEL", "openrouter/anthropic/claude-sonnet-5"),
     thinking_level: str = "",
     mode: str = "normal",
     plugins: SessionPlugins = SessionPlugins();


"""Set the active dev mode used for system-prompt and tool policy seams."""
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

glob _t0: float = 0.0,
     _n_tools: int = 0;

# Per-provider last-model memory (fx-style), persisted to
# <cwd>/.jackal/model_prefs.json. Loaded defensively once per process; a
# missing or corrupt file simply means no remembered preferences.
glob _model_prefs: dict[str, any] = {},
     _model_prefs_loaded: bool = False;


# ===================== MCP server attach =====================
#
# Config convention (read defensively from the walk-up .jackal JSON that
# load_project_config already resolves):
#
#   "mcp": {"servers": {"<name>": {"command": ["jac", "mcp"], "args": []}}}
#
# "command" may also be a single string; "args" is optional. Servers spawn
# lazily in background flows right after boot registration so the first frame
# is never blocked (D21); each server is failure-isolated — a dead or slow
# server logs and skips, never breaking boot.

"""Sanitize one name chunk for registry naming (mcp_<server>_<tool>)."""
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


"""Path of the per-project model preference file."""
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


"""Render one event from the loop to stdout (line-mode UI)."""
def render_event(kind: str, data: dict[str, any]) {
    out: any = sys.stdout;
    if kind == "chunk" {
        out.write(str(data.get("content", "")));
        out.flush();
    } elif kind == "tool_call" {
        out.write("\n");
        args: any = data.get("args", {});
        parts: list[str] = [];
        for pair in args.items() {
            parts.append(str(pair[0]) + "=" + str(pair[1])[:40]);
        }
        out.write(f"  * {data.get('tool')}({(', '.join(parts))[:120]})\n");
        out.flush();
        _n_tools += 1;
    } elif kind == "tool_result" {
        preview = str(data.get("result", ""))[:80].replace("\n", " ");
        out.write(f"    -> {preview}\n");
        out.flush();
    } elif kind == "error" {
        out.write(f"\n[error] {data.get('message')}\n");
        out.flush();
    } elif kind == "extensions" {
        out.write(f"\n[{data.get('label', '')}]\n");
        out.flush();
    }
}


"""Current extension readiness snapshot (dual clocks + loading n/m)."""
def extensions_status() -> ExtensionStatus {
    st = ExtensionStatus(
        phase=plugins.phase,
        loaded=plugins.loaded,
        total=plugins.total,
        ready=plugins.ready,
        detail=plugins.detail,
        t_interactive_s=plugins.t_interactive,
        t_ext_ready_s=plugins.t_ext_ready,
        compat_tier="",
    );
    b = plugins.bridge;
    if b is not None {
        st.compat_tier = b.compat_tier;
    }
    st.label = extensions_label(st);
    return st;
}


"""Warm Node sidecar and load sidecar decls (runs under flow)."""
def _warm_sidecar(decls: list[ExtensionDecl], base_cwd: str) {
    bridge = plugins.bridge;
    reg = plugins.reg;
    if bridge is None or reg is None {
        plugins.phase = "degraded";
        plugins.detail = "missing bridge/registry";
        plugins.ready = True;
        plugins.t_ext_ready = time.time();
        return;
    }
    try {
        plugins.phase = "starting";
        ensure_node_host(bridge);
        for d in decls {
            path = resolve_decl_path(d, base_cwd);
            load_extension_path(
                bridge,
                reg,
                d.id,
                path,
                requires=d.requires,
                has_ui=plugins.interactive_ui,
            );
            plugins.loaded += 1;
            plugins.phase = "loading";
        }
        plugins.phase = "ready";
        plugins.ready = True;
        plugins.detail = "";
        plugins.t_ext_ready = time.time();
        # T2-partial: mirror extension commands for the shell/UI layer.
        plugins.commands.update(bridge.commands);
        # Lifecycle hook: session is fully loaded (best-effort, never fatal).
        fire_hook(bridge as PluginBridge, "session_start", {
            "session_id": plugins.session_id,
        });
        # Pi lifecycle: project_trust fires once per boot right after
        # session_start. Best-effort — fire_project_trust never raises.
        try {
            fire_project_trust(bridge as PluginBridge, base_cwd);
        } except Exception {
        }
        # Lifecycle hook: surface discovered resource dirs once after load
        # (skills/prompts conventions; absent dirs are simply not listed).
        res_paths: list[str] = [];
        for cand in [
            os.path.join(base_cwd, ".jackal", "skills"),
            os.path.join(base_cwd, "skills"),
            os.path.join(base_cwd, ".jackal", "prompts"),
            os.path.join(base_cwd, "prompts"),
        ] {
            if os.path.isdir(cand) {
                res_paths.append(cand);
            }
        }
        fire_hook(bridge as PluginBridge, "resources_discover", {
            "paths": res_paths,
        });
    } except Exception as e {
        plugins.phase = "degraded";
        plugins.detail = str(e);
        plugins.ready = True;
        plugins.t_ext_ready = time.time();
        b = plugins.bridge;
        if b is not None {
            host_status(b);
        }
    }
}


"""Boot session plugins: first-frame clock + parallel sidecar when declared.

Returns extensions_status. No Node if undeclared.
"""
def session_boot(
    sid: str = "",
    cwd: str = "",
    decls: list[any] | None = None,
    wait_budget_s: float = 5.0,
    interactive_ui: bool = False,
) -> ExtensionStatus {
    requested_mode: str = os.environ.get("JACKAL_MODE", "");
    set_mode(requested_mode if requested_mode else "normal");
    plugins.session_id = sid if sid else "session";
    plugins.cwd = cwd if cwd else os.getcwd();
    plugins.interactive_ui = interactive_ui;
    plugins.wait_budget_s = wait_budget_s;
    plugins.t_interactive = time.time();
    plugins.t_ext_ready = 0.0;
    plugins.loaded = 0;
    plugins.detail = "";
    plugins.prompt_queue.clear();
    plugins.warm_future = None;

    parsed: list[ExtensionDecl] = [];
    if decls is not None {
        for item in decls {
            if isinstance(item, ExtensionDecl) {
                parsed.append(item);
            } elif isinstance(item, dict) {
                parsed.append(decl_from_dict(item));
            }
        }
    } else {
        parsed = load_extension_decls(plugins.cwd);
    }
    plugins.decls = parsed;
    plugins.reg = default_registry();
    # user_bash hook: tools.jac cannot import the bridge (import cycle), so
    # boot wraps the registered run_command handler; fire_user_bash never
    # raises and tolerates bridge=None.
    rt = get_tool(plugins.reg, "run_command");
    if rt is not None and rt.handler is not None {
        cell: dict[str, any] = {"fn": rt.handler};

        def _run_command_hooked(cmd: str, timeout_secs: int = 120) -> str {
            res = str(cell["fn"](cmd, timeout_secs));
            fire_user_bash(plugins.bridge as PluginBridge | None, cmd, res);
            return res;
        }
        rt.handler = _run_command_hooked;
    }
    # MCP attach (D21): config parse is a cheap sync file read; server spawns
    # run in background flows so boot/first frame is never blocked.
    try {
        _attach_mcp_servers(load_project_config(plugins.cwd));
    } except Exception {
    }

    # Model prefs: cheap defensive read so model_preferences()/set_model see
    # the project's remembered per-provider models; missing/corrupt is fine.
    _load_model_prefs();

    sidecar: own list[ExtensionDecl] = node_sidecar_decls(parsed);
    plugins.total = len(sidecar);
    if plugins.total == 0 {
        plugins.bridge = None;
        plugins.ready = True;
        plugins.phase = "idle";
        plugins.t_ext_ready = plugins.t_interactive;
        return extensions_status();
    }

    plugins.bridge = create_bridge(plugins.session_id);
    plugins.ready = False;
    plugins.phase = "starting";
    # Parallel warm — does not block the caller (first frame).
    warm_cwd: str = plugins.cwd;
    plugins.warm_future = flow _warm_sidecar(sidecar, warm_cwd);
    return extensions_status();
}


"""Block until extensions ready or wait budget expires (before model request)."""
def wait_extensions_ready(timeout_s: float = -1.0) -> ExtensionStatus {
    budget = timeout_s if timeout_s >= 0.0 else plugins.wait_budget_s;
    if plugins.ready and plugins.warm_future is None {
        return extensions_status();
    }
    wf = plugins.warm_future;
    if wf is not None {
        try {
            if budget <= 0.0 {
                wait wf;
            } else {
                deadline = time.monotonic() + budget;
                while not plugins.ready and time.monotonic() < deadline {
                    time.sleep(0.02);
                }
            }
        } except Exception as e {
            plugins.phase = "degraded";
            plugins.detail = str(e);
            plugins.ready = True;
            if plugins.t_ext_ready <= 0.0 {
                plugins.t_ext_ready = time.time();
            }
        }
    }
    if not plugins.ready {
        plugins.phase = "degraded";
        if not plugins.detail {
            plugins.detail = f"extension wait budget {budget}s expired";
        }
        plugins.ready = True;
        if plugins.t_ext_ready <= 0.0 {
            plugins.t_ext_ready = time.time();
        }
    }
    return extensions_status();
}


"""Queue a user prompt while extensions are still loading."""
def enqueue_prompt(message: str) -> int {
    plugins.prompt_queue.append(message);
    return len(plugins.prompt_queue);
}


def drain_prompt_queue() -> list[str] {
    out: list[str] = list(plugins.prompt_queue);
    plugins.prompt_queue.clear();
    return out;
}


def session_dispose {
    wf = plugins.warm_future;
    if wf is not None {
        try {
            wait wf;
        } except Exception {
        }
        plugins.warm_future = None;
    }
    # Stop any MCP server subprocesses (including ones mid-handshake).
    for (_mc_name, mc) in plugins.mcp_clients.items() {
        try {
            mcp_stop(mc);
        } except Exception {
        }
    }
    plugins.mcp_clients.clear();
    plugins.mcp_tools = 0;
    b = plugins.bridge;
    if b is not None {
        # Pi lifecycle: extensions get session_shutdown before teardown.
        try {
            fire_hook(b as PluginBridge, "session_shutdown", {});
        } except Exception {
        }
        dispose_bridge(b as PluginBridge);
        plugins.bridge = None;
    }
    plugins.reg = None;
    plugins.ready = True;
    plugins.phase = "idle";
    plugins.loaded = 0;
    plugins.total = 0;
    plugins.commands.clear();
}


"""Relay tool-loop events to extension listeners under Pi event names.

Returns an event handler that first fires the matching Pi hook
(tool_execution_start / tool_execution_end) then delegates to `inner`.
With no bridge this is the identity — zero overhead on the native path.
"""
def relay_tool_hooks(bridge: PluginBridge | None, inner: any) -> any {
    if bridge is None {
        return inner;
    }
    def relayed(kind: str, data: dict[str, any]) {
        if kind == "tool_call" {
            fire_hook(bridge, "tool_execution_start", {
                "tool": str(data.get("tool", "")),
                "args": data.get("args", {}),
            });
        } elif kind == "tool_result" {
            fire_hook(bridge, "tool_execution_end", {
                "tool": str(data.get("tool", "")),
                "result": str(data.get("result", ""))[:2000],
            });
        }
        inner(kind, data);
    }
    return relayed;
}


"""Best-effort application of extension traffic pushed during a turn.

sendMessage/sendUserMessage payloads join LLM context (history); entries
and ui_events are transcript-only and surface as `entry` events. Never
raises — extension traffic must not break the turn.
"""
def _apply_extension_traffic(bridge: PluginBridge | None, on_event: any) {
    if bridge is None or on_event is None {
        return;
    }
    try {
        traffic: dict[str, any] = drain_extension_traffic(bridge);
        msgs: list[dict[str, any]] = traffic["messages"];
        for m in msgs {
            history.append({"role": str(m.get("role", "user")), "content": str(m.get("content", ""))});
        }
        raw_entries: list[dict[str, any]] = traffic["entries"];
        for e in raw_entries {
            ent: dict[str, any] = dict(e);
            # P11: an entry renderer matching this type upgrades the entry
            # with native content lines (app/ui paints them via
            # set_node_content); unmatched entries pass through untouched.
            try {
                r: dict[str, any] = render_extension_block(
                    bridge as PluginBridge, "entry", str(ent.get("type", "")), ent.get("data")
                );
                if r.get("ok") and r.get("lines") {
                    ent["lines"] = r["lines"];
                }
            } except Exception {
            }
            on_event("entry", ent);
        }
    } except Exception {
    }
}


"""Apply extension-issued pi.setModel / pi.setThinkingLevel requests drained
from the bridge. Goes through set_model/set_thinking_level so model_select /
thinking_level_select reach all listeners exactly once per change. Never
raises — a broken extension must not break the turn."""
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


"""Best-effort auto-compaction of session history when the context threshold
is crossed (checked after the user message lands — matches src ordering).

Fires Pi's session_before_compact / session_after_compact hooks; a blocking
verdict ({block: true}) from any before-listener skips compaction this turn.
Never raises — compaction failure must not break the turn."""
def _maybe_auto_compact(bridge: PluginBridge | None) {
    try {
        cwd = plugins.cwd if plugins.cwd else os.getcwd();
        raw_cfg = load_project_config(cwd);
        cfg = resolve_auto_compact_config(
            raw_cfg, str(raw_cfg.get("compactStrategy", ""))
        );
        ctx_override: any = None;
        env_max: str = os.environ.get("JACKAL_CONTEXT_MAX", "");
        if env_max.isdigit() {
            ctx_override = int(env_max);
        }
        usage = compute_context_usage(history, ctx_override);
        if not should_auto_compact(usage, cfg) {
            return;
        }
        keep_tail: any = cfg.get("keepTail", 12);
        kt = int(keep_tail);
        if len(history) <= kt {
            return;
        }
        blocked = False;
        if bridge is not None {
            results = fire_hook(bridge as PluginBridge, "session_before_compact", {
                "messages_count": len(history),
                "percent": usage.get("percent"),
            });
            for r in results {
                v: any = r.get("verdict") if isinstance(r, dict) else None;
                if isinstance(v, dict) and v.get("block") {
                    blocked = True;
                    break;
                }
            }
        }
        if blocked {
            return;
        }
        count_before = len(history);
        dropped = history[:count_before - kt];
        kept = history[count_before - kt:];
        summary_text = build_mechanical_summary(dropped);
        strategy = "mechanical";
        if str(cfg.get("strategy", "mechanical")) == "llm" {
            llm_text = summarize_for_compaction(dropped, model, thinking_level);
            if llm_text is not None {
                summary_text = llm_text;
                strategy = "llm";
            }
        }
        compacted: list[dict[str, any]] = [{"role": "user", "content": summary_text}];
        for m in kept {
            compacted.append(m);
        }
        # Clear + refill (glob reassignment is a trap per SessionPlugins note).
        history.clear();
        for m in compacted {
            history.append(m);
        }
        if bridge is not None {
            fire_hook(bridge as PluginBridge, "session_after_compact", {
                "before": count_before,
                "after": len(history),
                "strategy": strategy,
            });
        }
    } except Exception {
    }
}


"""Seed or refresh the session system prompt for the active dev mode."""
def _ensure_mode_system_prompt {
    desired: str = system_prompt_for_mode(SYSTEM_PROMPT, mode);
    if not history {
        history.append({"role": "system", "content": desired});
        return;
    }
    for i in range(len(history)) {
        if str(history[i].get("role", "")) != "system" {
            continue;
        }
        current: str = str(history[i].get("content", ""));
        if (
            current == SYSTEM_PROMPT
            or "## Plan mode (active)" in current
            or "## Ask mode (active)" in current
        ) {
            history[i]["content"] = desired;
        }
        return;
    }
}


"""Run one agent turn: wait for extension snapshot, then stream the loop.

on_event(kind, data) is the UI boundary: the term renderer prints, the
JSONL renderer serializes - one protocol, two clients.
"""
def run_turn(
    message: str,
    on_event: any = render_event,
    approve: any = None,
) -> str {
    # Auto-boot with no decls if never booted (native-only path).
    if plugins.reg is None {
        session_boot(plugins.session_id, plugins.cwd if plugins.cwd else os.getcwd(), []);
    }
    st = wait_extensions_ready();
    # Extensions may have called pi.setModel/setThinkingLevel during load.
    _apply_pending_model_requests();
    if on_event is not None and st.total > 0 {
        on_event(
            "extensions",
            {
                "label": st.label,
                "phase": st.phase,
                "loaded": st.loaded,
                "total": st.total,
                "detail": st.detail,
                "t_interactive_s": st.t_interactive_s,
                "t_ext_ready_s": st.t_ext_ready_s,
                "compat_tier": st.compat_tier,
            },
        );
    }
    bridge = plugins.bridge;
    # Pi event order: input -> before_agent_start -> turn/agent start.
    # `input` verdicts: handled skips the agent entirely (extension already
    # gave feedback via ctx.ui) and leaves zero trace — evaluated BEFORE the
    # system-prompt seed so a handled first turn does not grow history.
    if bridge is not None {
        try {
            igate = input_gate(bridge as PluginBridge, message);
        } except Exception {
            igate = {"action": "continue", "text": message};
        }
        if igate.get("action") == "handled" {
            _apply_extension_traffic(bridge as PluginBridge, on_event);
            return "";
        }
        if igate.get("action") == "transform" {
            message = str(igate.get("text", message));
        }
    }
    _ensure_mode_system_prompt();
    history.append({"role": "user", "content": message});
    # Auto-compact seam: threshold check after the user message lands.
    _maybe_auto_compact(bridge);
    # P10: extension-declared models route through the provider seam;
    # anything else uses the native provider table.
    transport: any = None;
    if model.startswith("ext/") {
        try {
            transport = make_ext_transport(bridge as PluginBridge, model, thinking=thinking_level);
        } except Exception {
            transport = None;
        }
        if transport is None {
            if on_event is not None {
                on_event("error", {"message": f"unknown extension model {model}"});
            }
            return "";
        }
    }
    if transport is None {
        transport = make_transport(model, thinking_level, hook_bridge=bridge);
    }
    _t0 = time.time();
    _n_tools = 0;
    # T2-partial lifecycle hooks — best-effort, never fatal.
    injected_system = "";
    sys_idx = -1;
    saved_sys = "";
    if bridge is not None {
        b = bridge as PluginBridge;
        # before_agent_start verdicts: systemPrompt replaces the system prompt
        # for THIS turn (restored after), message joins session history.
        try {
            agate = agent_start_gate(b, message);
        } except Exception {
            agate = {"message": "", "systemPrompt": ""};
        }
        injected_system = str(agate.get("systemPrompt", ""));
        if injected_system {
            for i in range(len(history)) {
                if str(history[i].get("role", "")) == "system" {
                    sys_idx = i;
                    saved_sys = str(history[i].get("content", ""));
                    history[i]["content"] = injected_system;
                    break;
                }
            }
        }
        inj_msg = str(agate.get("message", ""));
        if inj_msg {
            history.append({"role": "user", "content": inj_msg});
        }
        fire_hook(b, "turn_start", {"message": message});
        fire_hook(b, "agent_start", {"message": message});
    }
    answer = "";
    # Cooperative abort handle for this turn (/abort flips it from the UI).
    turn_cancel = TurnCancel();
    plugins.active_cancel = turn_cancel;
    try {
        reg = plugins.reg if plugins.reg is not None else default_registry();
        answer = react_loop(
            history, [], transport, relay_tool_hooks(bridge, on_event),
            reg=reg, bridge=bridge, cancel=turn_cancel, approve=approve,
        );
    } finally {
        plugins.active_cancel = None;
        if sys_idx >= 0 {
            # Per-turn system prompt swap is undone — Pi semantics: the
            # replacement lasts for this turn's LLM calls only.
            try {
                history[sys_idx]["content"] = saved_sys;
            } except Exception {
            }
        }
        if on_event is render_event {
            sys.stdout.write("\n");
            if show_stats {
                sys.stdout.write(
                    f"  [{time.time() - _t0:.1f}s - {_n_tools} tools]\n"
                );
            }
            sys.stdout.flush();
        } else {
            on_event("turn_end", {"secs": time.time() - _t0, "tools": _n_tools});
        }
        if bridge is not None {
            b2 = bridge as PluginBridge;
            fire_hook(b2, "turn_end", {
                "secs": time.time() - _t0,
                "tools": _n_tools,
                "answer": answer,
            });
            fire_hook(b2, "agent_end", {"answer": answer});
            fire_hook(b2, "agent_settled", {});
            _apply_extension_traffic(b2, on_event);
        }
        # Best-effort transcript persistence after every turn. The boot-time
        # id may be a placeholder ("session") — mint a real one on first save.
        try {
            if not is_valid_session_id(plugins.session_id) {
                plugins.session_id = new_session_id();
            }
            save_session(
                plugins.cwd if plugins.cwd else os.getcwd(),
                history,
                session_id=plugins.session_id,
            );
        } except Exception {
        }
    }
    # T2b: display-only markdown transformer chain over the complete answer,
    # surfaced as a `message` event for JSON/UI clients (term mode ignores it
    # — the raw stream is already printed). Never mutates session history.
    if answer and on_event is not None {
        xres = transform_markdown(bridge, answer);
        shown = str(xres.get("markdown", answer)) if xres.get("ok") else answer;
        on_event("message", {"role": "assistant", "content": shown});
        # P11: extension message renderer produces native content lines for
        # the finalized assistant message (surfaced as an entry event so
        # line-based and native-screen clients share one protocol).
        if bridge is not None {
            try {
                mr: dict[str, any] = render_extension_block(
                    bridge as PluginBridge,
                    "message",
                    "assistant",
                    {"role": "assistant", "content": shown},
                );
                if mr.get("ok") and mr.get("lines") {
                    on_event("entry", {
                        "type": "extension_render",
                        "render_type": "assistant",
                        "lines": mr["lines"],
                    });
                }
            } except Exception {
            }
        }
    }
    return answer;
}


"""Read-only view of session history for the shell (/export, /sessions)."""
def get_history() -> list[dict[str, any]] {
    return list(history);
}


"""Replace in-memory history with a loaded transcript (restore flow)."""
def restore_history(msgs: list[dict[str, any]]) {
    history.clear();
    for m in msgs {
        if isinstance(m, dict) {
            history.append(dict(m));
        }
    }
}


def set_current_session_id(sid: str) {
    plugins.session_id = sid if sid else new_session_id();
}


"""Request cooperative abort of the active turn (if any). Safe to call from
the UI thread while run_turn is streaming. Returns True when a live turn was
flagged; False when no turn is in flight or it was already cancelled."""
def cancel_active_turn() -> bool {
    c = plugins.active_cancel;
    if c is not None and not c.cancelled {
        c.cancelled = True;
        return True;
    }
    return False;
}


"""Extension commands visible to the shell/UI (name -> description meta).

The bridge owns the authoritative set; this re-syncs from it so commands
registered/unloaded after warm-up are reflected immediately.
"""
def list_commands() -> dict[str, any] {
    b = plugins.bridge;
    if b is not None {
        plugins.commands = dict((b as PluginBridge).commands);
    }
    return dict(plugins.commands);
}


"""Invoke an extension command through the plugin bridge.

Returns a display string: the command result plus any ctx.ui.notify lines the
handler emitted. Never raises — failures come back as ERROR strings.
"""
def run_command(name: str, args: str = "") -> str {
    bridge = plugins.bridge;
    if bridge is None {
        return f"ERROR: no plugin host running (command /{name} unavailable)";
    }
    res: dict[str, any] = invoke_command(bridge as PluginBridge, name, args);
    # A command handler may have called pi.setModel/setThinkingLevel.
    _apply_pending_model_requests();
    lines: list[str] = [];
    for note in res.get("notifications", []) or [] {
        lines.append(str(note));
    }
    if res.get("ok") {
        result_s = str(res.get("result", ""));
        if result_s {
            lines.append(result_s);
        }
    } else {
        lines.append("ERROR: " + str(res.get("error", "command failed")));
    }
    return "\n".join(lines);
}


"""Fire an extension keyboard shortcut by key (TUI keybinding path).

Returns a display string: handler notifications + result, or an ERROR line.
Never raises. Shortcut handlers may call pi.setModel/setThinkingLevel.
"""
def run_extension_shortcut(key: str) -> str {
    bridge = plugins.bridge;
    if bridge is None {
        return f"ERROR: no plugin host running (shortcut {key} unavailable)";
    }
    res: dict[str, any] = invoke_shortcut(bridge as PluginBridge, key);
    _apply_pending_model_requests();
    lines: list[str] = [];
    for note in res.get("notifications", []) or [] {
        lines.append(str(note));
    }
    if res.get("ok") {
        result_s = str(res.get("result", ""));
        if result_s {
            lines.append(result_s);
        }
    } else {
        lines.append("ERROR: " + str(res.get("error", "shortcut failed")));
    }
    return "\n".join(lines);
}


"""Shortcut bindings registered by loaded extensions (key -> meta with
extension_id + description). Listed for host UIs; the TUI input loop matches
keypresses against these and fires them via run_extension_shortcut."""
def list_extension_shortcuts() -> dict[str, any] {
    return list_shortcuts(plugins.bridge);
}


"""Labels set by loaded extensions via pi.setLabel (id -> meta)."""
def list_extension_labels() -> dict[str, any] {
    return list_labels(plugins.bridge);
}


"""JSONL event sink: one serialized event per line on stdout. This IS the
harness's UI protocol."""
def json_event(kind: str, data: dict[str, any]) {
    line = json.dumps({"type": kind, **data});
    out: any = sys.stdout;
    out.write(line + "\n");
    out.flush();
}
