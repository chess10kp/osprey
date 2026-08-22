"""Jackal agent session — owned ReAct loop + StreamEvent-style rendering.

Owns the plugin bridge and parallel Node sidecar warm (D21). History is a
caller-owned list of OpenAI-shape message dicts. Model transport is rebuilt
from the model name on each turn so /model swaps are immediate.
"""

import sys;
import os;
import json;
import time;

import from .llm { Transport, react_loop, make_transport }
import from .tools { default_registry }
import from .system { SYSTEM_PROMPT }
import from .plugin_bridge {
    PluginBridge,
    create_bridge,
    dispose_bridge,
    host_status,
    ensure_node_host,
    load_extension_path,
}
import from .registry { ToolRegistry }
import from .extensions {
    ExtensionDecl,
    ExtensionStatus,
    load_extension_decls,
    node_sidecar_decls,
    extensions_label,
    resolve_decl_path,
    decl_from_dict,
}


"""Mutable plugin/session control-plane state (avoid glob reassignment traps)."""
obj SessionPlugins {
    has session_id: str = "session",
        cwd: str = "",
        bridge: PluginBridge | None = None,
        reg: ToolRegistry | None = None,
        decls: list = [],
        loaded: int = 0,
        total: int = 0,
        ready: bool = True,
        phase: str = "idle",
        detail: str = "",
        t_interactive: float = 0.0,
        t_ext_ready: float = 0.0,
        prompt_queue: list[str] = [],
        warm_future: any = None,
        wait_budget_s: float = 5.0;
}


glob history: list = [],
     show_stats: bool = True,
     model: str = os.environ.get("JACKAL_MODEL", "openrouter/anthropic/claude-sonnet-5"),
     plugins: SessionPlugins = SessionPlugins();

glob _t0: float = 0.0,
     _n_tools: int = 0;


def set_model(name: str) -> str {
    model = name;
    return model;
}


def clear_history {
    history.clear();
}


"""Render one event from the loop to stdout (line-mode UI)."""
def render_event(kind: str, data: dict) {
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
            );
            plugins.loaded += 1;
            plugins.phase = "loading";
        }
        plugins.phase = "ready";
        plugins.ready = True;
        plugins.detail = "";
        plugins.t_ext_ready = time.time();
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
    decls: list | None = None,
    wait_budget_s: float = 5.0,
) -> ExtensionStatus {
    plugins.session_id = sid if sid else "session";
    plugins.cwd = cwd if cwd else os.getcwd();
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

    sidecar = node_sidecar_decls(parsed);
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
    plugins.warm_future = flow _warm_sidecar(sidecar, plugins.cwd);
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
    b = plugins.bridge;
    if b is not None {
        dispose_bridge(b as PluginBridge);
        plugins.bridge = None;
    }
    plugins.reg = None;
    plugins.ready = True;
    plugins.phase = "idle";
    plugins.loaded = 0;
    plugins.total = 0;
}


"""Run one agent turn: wait for extension snapshot, then stream the loop.

on_event(kind, data) is the UI boundary: the term renderer prints, the
JSONL renderer serializes - one protocol, two clients.
"""
def run_turn(message: str, on_event: any = render_event) -> str {
    # Auto-boot with no decls if never booted (native-only path).
    if plugins.reg is None {
        session_boot(plugins.session_id, plugins.cwd if plugins.cwd else os.getcwd(), []);
    }
    st = wait_extensions_ready();
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
    if not history {
        history.append({"role": "system", "content": SYSTEM_PROMPT});
    }
    history.append({"role": "user", "content": message});
    transport = make_transport(model);
    _t0 = time.time();
    _n_tools = 0;
    try {
        reg = plugins.reg if plugins.reg is not None else default_registry();
        bridge = plugins.bridge;
        answer = react_loop(history, [], transport, on_event, reg=reg, bridge=bridge);
    } finally {
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
    }
    return answer;
}


"""JSONL event sink: one serialized event per line on stdout. This IS the
harness's UI protocol."""
def json_event(kind: str, data: dict) {
    line = json.dumps({"type": kind, **data});
    out: any = sys.stdout;
    out.write(line + "\n");
    out.flush();
}
