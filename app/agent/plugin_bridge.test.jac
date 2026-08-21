"""In-process plugin bridge tests (merged with agent/plugin_bridge.jac).

Proves lazy host hello, extension load/unload into the registry, js invoke via
registry.invoke, and protocol kind helpers — without spawning Node.
"""

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
    assert get_tool(reg, "read_file") is not None;
    assert get_tool(reg, "read_file").origin == "native";
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
