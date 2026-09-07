"""Plugin bridge state and tool dispatch."""

import json;

import from .protocol { Envelope, make_envelope }
import from .fake_host { FakePluginHost, ensure_host, touch_bridge }
import from .plugin_bridge_io {
    _write_node,
    _prepare_corr,
    _read_node_until,
}
import from .plugin_bridge_host { maybe_restart_host, host_status }
import from .plugin_bridge_traffic { _absorb_payload }

obj PluginBridge {
    has session_id: str = "",
        host: FakePluginHost | None = None,
        host_kind: str = "",
        proc: any = None,
        node_bin: str = "node",
        host_mjs: str = "",
        next_corr: int = 1,
        inbox: list[Envelope] = [],
        last_active: float = 0.0,
        status_phase: str = "idle",
        idle_timeout_s: float = 300.0,
        pending: dict[str, any] = {},
        reply_q: any = None,
        reader_stop: any = None,
        reader_thread: any = None,
        write_lock: any = None,
        restart_used: bool = False,
        host_caps: list[str] = [],
        compat_tier: str = "T0",
        hello_payload: dict[str, any] = {},
        commands: dict[str, any] = {},
        md_transformers: list[dict[str, any]] = [],
        providers: dict[str, any] = {},
        ui_q: any = None,
        interactive_ui: bool = False,
        traffic_messages: list[dict[str, any]] = [],
        traffic_entries: list[dict[str, any]] = [],
        session_name: str = "",
        shortcuts: dict[str, any] = {},
        labels: dict[str, any] = {},
        pending_model: str = "",
        pending_thinking_level: str = "";

    """Dispatch a js tool (fake or Node) — used by registry.invoke."""
    def invoke_js_tool(name: str, args: dict[str, any]) -> str {
        return invoke_tool(self, name, args);
    }
}


# ── Checker shims ───────────────────────────────────────────────────────
def create_bridge(session_id: str) -> PluginBridge {
    return PluginBridge(session_id=session_id);
}
def _alloc_corr(bridge: PluginBridge) -> str {
    corr = "corr-" + str(bridge.next_corr);
    bridge.next_corr += 1;
    return corr;
}


def _node_alive(bridge: PluginBridge) -> bool {
    if bridge.host_kind != "node" or bridge.proc is None {
        return False;
    }
    return bridge.proc.poll() is None;
}


"""Push host_status into inbox and record phase (D13 degraded visibility)."""
def _emit_host_status(bridge: PluginBridge, phase: str, detail: str = "") {
    bridge.status_phase = phase;
    bridge.inbox.append(
        make_envelope(
            kind="host_status",
            session_id=bridge.session_id,
            payload={"phase": phase, "detail": detail},
        )
    );
}


"""Invoke a js tool via tool_invoke / tool_result (fake or Node)."""
def invoke_tool(bridge: PluginBridge, name: str, args: dict[str, any]) -> str {
    # Surface dead Node before attempting RPC (D13 degraded, never crash).
    if bridge.host_kind == "node" and not _node_alive(bridge) {
        host_status(bridge);
        return "ERROR: plugin host unavailable";
    }
    if bridge.host_kind == "node" {
        result = _invoke_tool_node(bridge, name, args);
    } else {
        result = _invoke_tool_fake(bridge, name, args);
    }
    if not str(result).startswith("ERROR: plugin host unavailable") {
        touch_bridge(bridge);
    } elif bridge.host_kind == "node" {
        host_status(bridge);
    }
    return result;
}


def _invoke_tool_fake(bridge: PluginBridge, name: str, args: dict[str, any]) -> str {
    ensure_host(bridge);
    h = bridge.host;
    if h is None or not h.alive {
        return "ERROR: plugin host unavailable";
    }
    corr = _alloc_corr(bridge);
    if corr in h.cancelled {
        result_env = make_envelope(
            kind="tool_result",
            session_id=bridge.session_id,
            tool_id=name,
            correlation_id=corr,
            payload={"ok": False, "error": "cancelled"},
        );
        bridge.inbox.append(result_env);
        return "ERROR: cancelled";
    }
    if name not in h.handlers {
        bridge.inbox.append(
            make_envelope(
                kind="tool_result",
                session_id=bridge.session_id,
                tool_id=name,
                correlation_id=corr,
                payload={"ok": False, "error": f"unknown tool {name}"},
            )
        );
        return f"ERROR: unknown js tool {name}";
    }
    # Fake-host parity for active-tool enforcement (B1).
    if h.active_tools is not None and name not in h.active_tools {
        bridge.inbox.append(
            make_envelope(
                kind="tool_result",
                session_id=bridge.session_id,
                tool_id=name,
                correlation_id=corr,
                payload={"ok": False, "error": f"tool {name} is not active"},
            )
        );
        return f"ERROR: tool {name} is not active";
    }
    try {
        result = str(h.handlers[name](**args));
        ok = True;
        err = "";
    } except Exception as e {
        result = "";
        ok = False;
        err = str(e);
    }
    payload: dict[str, any] = {"ok": ok};
    if ok {
        payload["result"] = result;
    } else {
        payload["error"] = err if err else "invoke failed";
    }
    bridge.inbox.append(
        make_envelope(
            kind="tool_result",
            session_id=bridge.session_id,
            tool_id=name,
            correlation_id=corr,
            payload=payload,
        )
    );
    if ok {
        return result;
    }
    return f"ERROR: {payload['error']}";
}


def _invoke_tool_node(bridge: PluginBridge, name: str, args: dict[str, any]) -> str {
    if not _node_alive(bridge) {
        phase = maybe_restart_host(bridge);
        if phase != "ready" or not _node_alive(bridge) {
            return "ERROR: plugin host unavailable";
        }
    }
    corr = _alloc_corr(bridge);
    _prepare_corr(bridge, corr, expect_kind="tool_result");
    req = make_envelope(
        kind="tool_invoke",
        session_id=bridge.session_id,
        tool_id=name,
        correlation_id=corr,
        payload={"name": name, "args": args},
    );
    try {
        _write_node(bridge, req);
        reply = _read_node_until(
            bridge, "tool_result", correlation_id=corr, timeout=10.0
        );
    } except Exception as e {
        return f"ERROR: {e}";
    }
    ok = bool(reply.payload.get("ok", False));
    _absorb_payload(bridge, dict(reply.payload));
    if ok {
        return str(reply.payload.get("result", ""));
    }
    return f"ERROR: {reply.payload.get('error', 'invoke failed')}";
}
