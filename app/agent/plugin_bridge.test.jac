"""In-process plugin bridge tests (merged with agent/plugin_bridge.jac).

Proves lazy host hello, extension load/unload into the registry, js invoke via
registry.invoke, and protocol kind helpers — without spawning Node.
"""

import os;
import time;

import from .tools { default_registry }
import from .registry {
    create_registry,
    get_tool,
    invoke,
    as_tool_specs,
}
import from .protocol {
    is_plugin_kind,
    is_ui_kind,
    make_plugin_envelope,
}


def _echo(text: str) -> str {
    return "JS:" + text;
}


test "ensure_host emits host_hello and is lazy" {
    bridge = create_bridge("s1");
    assert bridge.host is None;
    phase = ensure_host(bridge);
    assert phase == "ready";
    assert bridge.host is not None;
    kinds = drain_inbox(bridge);
    assert "host_hello" in kinds;
    ensure_host(bridge);
    assert drain_inbox(bridge) == [];
}


test "load_extension registers js tools and invoke round-trips" {
    bridge = create_bridge("s-load");
    reg = create_registry();
    names = load_extension(
        bridge,
        reg,
        "stub.echo",
        [
            {
                "name": "echo",
                "description": "echo via js",
                "parameters": {
                    "type": "object",
                    "properties": {"text": {"type": "string"}},
                    "required": ["text"],
                },
            }
        ],
        {"echo": _echo},
    );
    assert names == ["echo"];
    entry = get_tool(reg, "echo");
    assert entry is not None;
    assert entry.origin == "js";
    assert entry.extension_id == "stub.echo";
    kinds = drain_inbox(bridge);
    assert "host_hello" in kinds;
    assert "ext_loaded" in kinds;
    result = invoke(reg, "echo", {"text": "hi"}, bridge);
    assert result == "JS:hi";
    kinds2 = drain_inbox(bridge);
    assert "tool_result" in kinds2;
}


test "default_registry is native-only until extension loads" {
    reg = default_registry();
    native = get_tool(reg, "read_file");
    assert native is not None;
    assert native.origin == "native";
    native_n = len(as_tool_specs(reg));
    assert native_n >= 5;
    bridge = create_bridge("s-def");
    load_extension(
        bridge,
        reg,
        "stub.echo",
        [{"name": "echo", "description": "e", "parameters": {}}],
        {"echo": _echo},
    );
    assert len(as_tool_specs(reg)) == native_n + 1;
    assert invoke(reg, "echo", {"text": "x"}, bridge) == "JS:x";
}


test "unload_extension removes js tools only" {
    bridge = create_bridge("s-un");
    reg = default_registry();
    load_extension(
        bridge,
        reg,
        "stub.echo",
        [{"name": "echo", "description": "e", "parameters": {}}],
        {"echo": _echo},
    );
    n = unload_extension(bridge, reg, "stub.echo");
    assert n == 1;
    assert get_tool(reg, "echo") is None;
    assert get_tool(reg, "read_file") is not None;
}


test "dispose_bridge marks host dead" {
    bridge = create_bridge("s-dis");
    ensure_host(bridge);
    dispose_bridge(bridge);
    assert bridge.host is None;
    kinds = drain_inbox(bridge);
    assert "host_goodbye" in kinds;
}


test "plugin and ui kind helpers partition the seam" {
    assert is_ui_kind("text_delta");
    assert is_ui_kind("turn_start");
    assert not is_ui_kind("tool_invoke");
    assert is_plugin_kind("tool_invoke");
    assert is_plugin_kind("host_hello");
    assert not is_plugin_kind("text_delta");
    env = make_plugin_envelope(
        kind="tool_result",
        payload={"ok": True, "result": "x"},
        session_id="s",
        correlation_id="c1",
        tool_id="echo",
    );
    assert env.kind == "tool_result";
    assert env.correlation_id == "c1";
    raised = False;
    try {
        make_plugin_envelope(kind="text_delta", payload={"text": "no"});
    } except ValueError {
        raised = True;
    }
    assert raised;
}


test "node host load stub_echo and invoke round-trip" {
    bridge = create_bridge("s-node");
    reg = create_registry();
    phase = ensure_node_host(bridge);
    assert phase == "ready";
    assert bridge.host_kind == "node";
    kinds = drain_inbox(bridge);
    # starting status + hello (hello may race; hello_payload is authoritative)
    assert bridge.hello_payload.get("protocol") == 1;
    assert "tools" in bridge.host_caps;
    if "host_hello" not in kinds {
        assert "host_status" in kinds or bridge.compat_tier != "";
    }
    stub = resolve_stub_echo();
    names = load_extension_path(bridge, reg, "stub.echo", stub);
    assert "echo" in names;
    entry = get_tool(reg, "echo");
    assert entry is not None;
    assert entry.origin == "js";
    result = invoke(reg, "echo", {"text": "hi"}, bridge);
    assert result == "ECHO:hi";
    dispose_bridge(bridge);
    assert bridge.proc is None;
}


test "cold path never spawns node until ensure_node_host" {
    bridge = create_bridge("s-cold");
    assert bridge.proc is None;
    assert bridge.host_kind == "";
    ensure_host(bridge);
    assert bridge.host_kind == "fake";
    assert bridge.proc is None;
    dispose_bridge(bridge);
}


test "maybe_reap_idle reaps node host and emits host_status" {
    bridge = create_bridge("s-reap");
    reg = create_registry();
    ensure_node_host(bridge);
    assert bridge.host_kind == "node";
    drain_inbox(bridge);
    # Force idle clock into the past and reap with a tiny timeout.
    bridge.last_active = 1.0;
    reaped = maybe_reap_idle(bridge, idle_timeout_s=0.01, now=100.0);
    assert reaped;
    assert bridge.proc is None;
    kinds = drain_inbox(bridge);
    assert "host_status" in kinds;
}


test "host_status marks degraded when node dies" {
    bridge = create_bridge("s-deg");
    ensure_node_host(bridge);
    drain_inbox(bridge);
    # Kill the child without going through dispose.
    bridge.proc.kill();
    bridge.proc.wait(timeout=2.0);
    phase = host_status(bridge);
    assert phase == "degraded";
    kinds = drain_inbox(bridge);
    assert "host_status" in kinds;
}


test "node host loads real Pi greet extension" {
    bridge = create_bridge("s-pi");
    reg = create_registry();
    ensure_node_host(bridge);
    path = resolve_pi_greet();
    names = load_extension_path(bridge, reg, "pi.greet", path);
    assert "greet" in names;
    entry = get_tool(reg, "greet");
    assert entry is not None;
    assert entry.origin == "js";
    result = invoke(reg, "greet", {"name": "Jac"}, bridge);
    assert result == "Hello, Jac!";
    dispose_bridge(bridge);
}


test "resolve_node_bin returns executable path" {
    bin = resolve_node_bin();
    assert bin;
    assert "node" in bin;
}


test "host_hello advertises compat tier and caps" {
    bridge = create_bridge("s-caps");
    ensure_node_host(bridge);
    assert bridge.compat_tier in ("T0", "T1");
    assert "tools" in bridge.host_caps;
    assert "cancel" in bridge.host_caps;
    dispose_bridge(bridge);
}


test "load_extension_path rejects unsupported requires" {
    bridge = create_bridge("s-req");
    reg = create_registry();
    ensure_node_host(bridge);
    stub = resolve_stub_echo();
    raised = False;
    try {
        load_extension_path(
            bridge, reg, "stub.echo", stub, requires=["commands"]
        );
    } except RuntimeError {
        raised = True;
    }
    assert raised;
    dispose_bridge(bridge);
}


test "tool_cancel aborts slow Pi tool" {
    bridge = create_bridge("s-cancel");
    reg = create_registry();
    ensure_node_host(bridge);
    host = resolve_host_mjs();
    slow = os.path.join(os.path.dirname(host), "fixtures", "pi_slow.mjs");
    load_extension_path(bridge, reg, "pi.slow", slow);
    # Fire invoke on a worker thread; cancel shortly after.
    import threading;
    box: dict = {"result": ""};

    def _run {
        box["result"] = invoke(
            reg, "slow_echo", {"text": "x", "ms": 2000}, bridge
        );
    }

    t = threading.Thread(target=_run, daemon=True);
    t.start();
    time.sleep(0.15);
    # Cancel the most recent correlation (next_corr-1).
    corr = "corr-" + str(bridge.next_corr - 1);
    cancel_tool(bridge, corr);
    t.join(timeout=5.0);
    assert "cancel" in box["result"] or "ERROR" in box["result"];
    dispose_bridge(bridge);
}
