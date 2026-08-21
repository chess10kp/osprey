"""Plugin bridge — fake in-process host + lazy Node host (D11/D13).

Speaks the same Envelope types as agent.protocol. Default path stays fake (no
Node). ensure_node_host spawns app/plugin_host/host.mjs over stdio JSONL once
per bridge; load_extension_path / invoke_tool round-trip through that process.
"""

import json;
import os;
import select;
import subprocess;
import time;

import from .protocol {
    Envelope,
    make_envelope,
    is_plugin_kind,
}
import from .registry {
    ToolRegistry,
    register_js,
    unregister_extension,
}


obj FakePluginHost {
    has handlers: dict[str, any] = {},
        extension_tools: dict[str, list[str]] = {},
        cancelled: set[str] = set(),
        node_version: str = "fake",
        alive: bool = True;
}


obj PluginBridge {
    has session_id: str = "",
        host: FakePluginHost | None = None,
        host_kind: str = "",
        proc: any = None,
        node_bin: str = "node",
        host_mjs: str = "",
        next_corr: int = 1,
        outbox: list[Envelope] = [],
        inbox: list[Envelope] = [];

    """Dispatch a js tool (fake or Node) — used by registry.invoke."""
    def invoke_js_tool(name: str, args: dict) -> str {
        return invoke_tool(self, name, args);
    }
}


def create_bridge(session_id: str) -> PluginBridge {
    return PluginBridge(session_id=session_id);
}


def create_fake_host(node_version: str = "fake") -> FakePluginHost {
    return FakePluginHost(node_version=node_version);
}


"""Resolve plugin_host/host.mjs from cwd (app/ or repo root)."""
def resolve_host_mjs(explicit: str = "") -> str {
    if explicit {
        if os.path.isfile(explicit) {
            return os.path.abspath(explicit);
        }
        raise FileNotFoundError(f"host.mjs not found: {explicit}");
    }
    cwd = os.getcwd();
    candidates = [
        os.path.join(cwd, "plugin_host", "host.mjs"),
        os.path.join(cwd, "app", "plugin_host", "host.mjs"),
    ];
    here = os.path.dirname(os.path.abspath(__file__));
    candidates.append(os.path.join(here, "..", "plugin_host", "host.mjs"));
    for c in candidates {
        if os.path.isfile(c) {
            return os.path.abspath(c);
        }
    }
    raise FileNotFoundError("plugin_host/host.mjs not found (run from app/ or repo root)");
}


"""Resolve fixtures/stub_echo.mjs beside the host."""
def resolve_stub_echo(explicit: str = "") -> str {
    if explicit {
        if os.path.isfile(explicit) {
            return os.path.abspath(explicit);
        }
        raise FileNotFoundError(f"stub_echo not found: {explicit}");
    }
    host = resolve_host_mjs();
    path = os.path.join(os.path.dirname(host), "fixtures", "stub_echo.mjs");
    if not os.path.isfile(path) {
        raise FileNotFoundError(f"stub_echo fixture missing: {path}");
    }
    return path;
}


def envelope_to_dict(env: Envelope) -> dict {
    return {
        "version": env.version,
        "session_id": env.session_id,
        "request_id": env.request_id,
        "turn_id": env.turn_id,
        "tool_id": env.tool_id,
        "sequence": env.sequence,
        "correlation_id": env.correlation_id,
        "kind": env.kind,
        "payload": env.payload if env.payload is not None else {},
    };
}


def envelope_from_dict(data: dict) -> Envelope {
    raw_payload: any = data.get("payload", {});
    payload: dict = {};
    if isinstance(raw_payload, dict) {
        payload = raw_payload;
    }
    return make_envelope(
        kind=str(data.get("kind", "")),
        payload=payload,
        session_id=str(data.get("session_id", "")),
        request_id=str(data.get("request_id", "")),
        turn_id=str(data.get("turn_id", "")),
        tool_id=str(data.get("tool_id", "")),
        sequence=int(data.get("sequence", 0)),
        correlation_id=str(data.get("correlation_id", "")),
        version=int(data.get("version", 1)),
    );
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


def _write_node(bridge: PluginBridge, env: Envelope) {
    if not _node_alive(bridge) {
        raise RuntimeError("plugin node host not running");
    }
    line = json.dumps(envelope_to_dict(env)) + "\n";
    bridge.proc.stdin.write(line);
    bridge.proc.stdin.flush();
    bridge.outbox.append(env);
}


def _read_node(bridge: PluginBridge, timeout: float = 5.0) -> Envelope {
    if not _node_alive(bridge) {
        raise RuntimeError("plugin node host not running");
    }
    deadline = time.monotonic() + timeout;
    while time.monotonic() < deadline {
        remaining = deadline - time.monotonic();
        (ready, _w, _x) = select.select([bridge.proc.stdout], [], [], remaining);
        if not ready {
            break;
        }
        line_raw: any = bridge.proc.stdout.readline();
        if not line_raw {
            raise RuntimeError("plugin node host closed stdout");
        }
        line_s: str = str(line_raw);
        parsed: any = json.loads(line_s);
        if not isinstance(parsed, dict) {
            raise RuntimeError("plugin host sent non-object JSON");
        }
        env = envelope_from_dict(parsed);
        bridge.inbox.append(env);
        return env;
    }
    raise TimeoutError("timed out waiting for plugin host reply");
}


"""Read until an envelope with kind matches (or timeout)."""
def _read_node_until(
    bridge: PluginBridge, kind: str, correlation_id: str = "", timeout: float = 5.0
) -> Envelope {
    deadline = time.monotonic() + timeout;
    while time.monotonic() < deadline {
        remaining = max(0.05, deadline - time.monotonic());
        env = _read_node(bridge, timeout=remaining);
        if env.kind == kind {
            if not correlation_id or env.correlation_id == correlation_id {
                return env;
            }
        }
        # Non-matching plugin traffic stays in inbox for drain_inbox.
    }
    raise TimeoutError(f"timed out waiting for {kind}");
}


"""Attach an in-process host (lazy ensure). Emits host_hello into inbox."""
def ensure_host(bridge: PluginBridge, host: FakePluginHost | None = None) -> str {
    if bridge.host_kind == "node" and _node_alive(bridge) {
        return "ready";
    }
    if bridge.host is not None and bridge.host.alive {
        return "ready";
    }
    h = host if host is not None else create_fake_host();
    bridge.host = h;
    bridge.host_kind = "fake";
    h.alive = True;
    bridge.inbox.append(
        make_envelope(
            kind="host_hello",
            session_id=bridge.session_id,
            payload={
                "protocol": 1,
                "node": h.node_version,
                "caps": ["tools"],
            },
        )
    );
    return "ready";
}


"""Spawn the Node plugin host (lazy). Emits host_hello from the child."""
def ensure_node_host(
    bridge: PluginBridge,
    host_mjs: str = "",
    node_bin: str = "node",
    timeout: float = 5.0,
) -> str {
    if _node_alive(bridge) {
        return "ready";
    }
    if bridge.host is not None {
        bridge.host.alive = False;
        bridge.host = None;
    }
    path = resolve_host_mjs(host_mjs);
    bridge.host_mjs = path;
    bridge.node_bin = node_bin;
    bridge.proc = subprocess.Popen(
        [node_bin, path],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    );
    bridge.host_kind = "node";
    hello = _read_node(bridge, timeout=timeout);
    if hello.kind != "host_hello" {
        dispose_bridge(bridge);
        raise RuntimeError(f"expected host_hello, got {hello.kind}");
    }
    return "ready";
}


def dispose_bridge(bridge: PluginBridge) {
    if bridge.host_kind == "node" and bridge.proc is not None {
        try {
            if bridge.proc.poll() is None {
                bye = make_envelope(
                    kind="host_goodbye",
                    session_id=bridge.session_id,
                    payload={"reason": "dispose"},
                );
                try {
                    _write_node(bridge, bye);
                    _read_node_until(bridge, "host_goodbye", timeout=2.0);
                } except Exception {
                }
                bridge.proc.terminate();
                try {
                    bridge.proc.wait(timeout=2.0);
                } except subprocess.TimeoutExpired {
                    bridge.proc.kill();
                    bridge.proc.wait(timeout=2.0);
                }
            }
        } except Exception {
        }
        bridge.proc = None;
        bridge.host_kind = "";
        bridge.inbox.append(
            make_envelope(
                kind="host_goodbye",
                session_id=bridge.session_id,
                payload={"reason": "dispose"},
            )
        );
        bridge.outbox.clear();
        return;
    }
    if bridge.host is not None {
        bridge.host.alive = False;
        bridge.inbox.append(
            make_envelope(
                kind="host_goodbye",
                session_id=bridge.session_id,
                payload={"reason": "dispose"},
            )
        );
    }
    bridge.host = None;
    bridge.host_kind = "";
    bridge.outbox.clear();
}


"""Install a stub extension into the fake host and registry.

`tool_defs` entries: {name, description, parameters}.
`handlers` maps tool name → callable.
"""
def load_extension(
    bridge: PluginBridge,
    reg: ToolRegistry,
    extension_id: str,
    tool_defs: list,
    handlers: dict[str, any],
) -> list[str] {
    if bridge.host_kind == "node" {
        raise RuntimeError("use load_extension_path for the Node host");
    }
    ensure_host(bridge);
    h = bridge.host;
    if h is None or not h.alive {
        raise RuntimeError("plugin host unavailable");
    }
    corr = _alloc_corr(bridge);
    bridge.outbox.append(
        make_envelope(
            kind="ext_load",
            session_id=bridge.session_id,
            correlation_id=corr,
            payload={"id": extension_id, "path": "in-process:" + extension_id},
        )
    );
    names: list[str] = [];
    schemas: list = [];
    for td in tool_defs {
        t: any = td;
        name = str(t.get("name", ""));
        if not name {
            continue;
        }
        names.append(name);
        raw_params: any = t.get("parameters", {});
        params: dict = {};
        if isinstance(raw_params, dict) {
            params = raw_params;
        }
        schemas.append({
            "name": name,
            "description": str(t.get("description", "")),
            "parameters": params,
        });
        if name in handlers {
            h.handlers[name] = handlers[name];
        }
        register_js(
            reg,
            name=name,
            description=str(t.get("description", "")),
            parameters=params,
            extension_id=extension_id,
        );
    }
    h.extension_tools[extension_id] = names;
    bridge.inbox.append(
        make_envelope(
            kind="ext_loaded",
            session_id=bridge.session_id,
            correlation_id=corr,
            payload={"id": extension_id, "tools": schemas},
        )
    );
    if bridge.outbox {
        bridge.outbox.pop(0);
    }
    return names;
}


"""Load a real JS module into the Node host and register its tools."""
def load_extension_path(
    bridge: PluginBridge,
    reg: ToolRegistry,
    extension_id: str,
    path: str,
    timeout: float = 5.0,
) -> list[str] {
    ensure_node_host(bridge);
    abs_path = os.path.abspath(path);
    if not os.path.isfile(abs_path) {
        raise FileNotFoundError(f"extension module not found: {abs_path}");
    }
    corr = _alloc_corr(bridge);
    req = make_envelope(
        kind="ext_load",
        session_id=bridge.session_id,
        correlation_id=corr,
        payload={"id": extension_id, "path": abs_path},
    );
    _write_node(bridge, req);
    if bridge.outbox {
        bridge.outbox.pop(0);
    }
    reply = _read_node_until(bridge, "ext_loaded", correlation_id=corr, timeout=timeout);
    err = reply.payload.get("error", "");
    if err {
        raise RuntimeError(f"ext_load failed: {err}");
    }
    tools = reply.payload.get("tools", []);
    names: list[str] = [];
    for td in tools {
        t: any = td;
        name = str(t.get("name", ""));
        if not name {
            continue;
        }
        names.append(name);
        raw_params: any = t.get("parameters", {});
        params: dict = {};
        if isinstance(raw_params, dict) {
            params = raw_params;
        }
        register_js(
            reg,
            name=name,
            description=str(t.get("description", "")),
            parameters=params,
            extension_id=extension_id,
        );
    }
    return names;
}


def unload_extension(
    bridge: PluginBridge, reg: ToolRegistry, extension_id: str
) -> int {
    removed = unregister_extension(reg, extension_id);
    if bridge.host_kind == "node" and _node_alive(bridge) {
        req = make_envelope(
            kind="ext_unload",
            session_id=bridge.session_id,
            payload={"id": extension_id},
        );
        try {
            _write_node(bridge, req);
            if bridge.outbox {
                bridge.outbox.pop(0);
            }
        } except Exception {
        }
        return removed;
    }
    ensure_host(bridge);
    h = bridge.host;
    if h is not None {
        names = h.extension_tools.pop(extension_id, []);
        for name in names {
            if name in h.handlers {
                del h.handlers[name];
            }
        }
    }
    bridge.outbox.append(
        make_envelope(
            kind="ext_unload",
            session_id=bridge.session_id,
            payload={"id": extension_id},
        )
    );
    if bridge.outbox {
        bridge.outbox.pop(0);
    }
    return removed;
}


"""Invoke a js tool via tool_invoke / tool_result (fake or Node)."""
def invoke_tool(bridge: PluginBridge, name: str, args: dict) -> str {
    if bridge.host_kind == "node" {
        return _invoke_tool_node(bridge, name, args);
    }
    return _invoke_tool_fake(bridge, name, args);
}


def _invoke_tool_fake(bridge: PluginBridge, name: str, args: dict) -> str {
    ensure_host(bridge);
    h = bridge.host;
    if h is None or not h.alive {
        return "ERROR: plugin host unavailable";
    }
    corr = _alloc_corr(bridge);
    bridge.outbox.append(
        make_envelope(
            kind="tool_invoke",
            session_id=bridge.session_id,
            tool_id=name,
            correlation_id=corr,
            payload={"name": name, "args": args},
        )
    );
    if corr in h.cancelled {
        bridge.outbox.pop(0);
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
        bridge.outbox.pop(0);
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
    try {
        result = str(h.handlers[name](**args));
        ok = True;
        err = "";
    } except Exception as e {
        result = "";
        ok = False;
        err = str(e);
    }
    if bridge.outbox {
        bridge.outbox.pop(0);
    }
    payload: dict = {"ok": ok};
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


def _invoke_tool_node(bridge: PluginBridge, name: str, args: dict) -> str {
    if not _node_alive(bridge) {
        return "ERROR: plugin host unavailable";
    }
    corr = _alloc_corr(bridge);
    req = make_envelope(
        kind="tool_invoke",
        session_id=bridge.session_id,
        tool_id=name,
        correlation_id=corr,
        payload={"name": name, "args": args},
    );
    try {
        _write_node(bridge, req);
        if bridge.outbox {
            bridge.outbox.pop(0);
        }
        reply = _read_node_until(
            bridge, "tool_result", correlation_id=corr, timeout=10.0
        );
    } except Exception as e {
        return f"ERROR: {e}";
    }
    ok = bool(reply.payload.get("ok", False));
    if ok {
        return str(reply.payload.get("result", ""));
    }
    return f"ERROR: {reply.payload.get('error', 'invoke failed')}";
}


def cancel_tool(bridge: PluginBridge, correlation_id: str) {
    if bridge.host_kind == "node" and _node_alive(bridge) {
        req = make_envelope(
            kind="tool_cancel",
            session_id=bridge.session_id,
            correlation_id=correlation_id,
            payload={},
        );
        try {
            _write_node(bridge, req);
        } except Exception {
        }
        return;
    }
    ensure_host(bridge);
    h = bridge.host;
    if h is not None {
        h.cancelled.add(correlation_id);
    }
    bridge.outbox.append(
        make_envelope(
            kind="tool_cancel",
            session_id=bridge.session_id,
            correlation_id=correlation_id,
            payload={},
        )
    );
}


"""Drain inbox plugin envelopes; return kinds seen (tests / status)."""
def drain_inbox(bridge: PluginBridge) -> list[str] {
    kinds: list[str] = [];
    while bridge.inbox {
        env = bridge.inbox.pop(0);
        if is_plugin_kind(env.kind) {
            kinds.append(env.kind);
        }
    }
    return kinds;
}
