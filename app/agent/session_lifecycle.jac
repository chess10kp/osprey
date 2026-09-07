"""Extension and MCP lifecycle for an agent session."""

import os;
import time;

import from .session_state { plugins }
import from .session_config { set_mode, _attach_mcp_servers, _load_model_prefs }
import from .compaction { load_project_config }
import from .tools { default_registry }
import from .registry { get_tool }
import from .plugin_bridge {
    PluginBridge,
    create_bridge,
    dispose_bridge,
    host_status,
    ensure_node_host,
    load_extension_path,
    fire_hook,
    fire_user_bash,
    fire_project_trust,
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
import from .mcp { McpClient, mcp_stop }


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

