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
    assert bridge.compat_tier in ("T0", "T1", "T2-partial");
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
            bridge, reg, "stub.echo", stub, requires=["renderers"]
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
    slow = os.path.join(os.path.dirname(str(host)), "fixtures", "pi_slow.mjs");
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


# ===================== T2-partial: commands + hooks =====================

test "fake host command invoke round-trips with notifications" {
    bridge = create_bridge("s-cmd");
    reg = create_registry();

    def _upper(args: str, ctx: any) -> str {
        out = str(args).strip().upper();
        ctx["ui"].notify("UPPER:" + out);
        return out;
    }

    register_fake_command(bridge, "upper", _upper, description="Uppercase args");
    assert "upper" in bridge.commands;
    assert bridge.commands["upper"]["extension_id"] == "fake.commands";

    res = invoke_command(bridge, "upper", "hello jackal");
    assert res["ok"] is True;
    assert res["result"] == "HELLO JACKAL";
    assert res["notifications"] == ["UPPER:HELLO JACKAL"];

    missing = invoke_command(bridge, "nope", "");
    assert missing["ok"] is False;
    assert "unknown command" in missing["error"];
}


test "fake host hook fire runs listeners serially and isolates errors" {
    bridge = create_bridge("s-hook");
    order: list[str] = [];

    def _h1(event_data: dict, ctx: any) -> str {
        order.append("h1");
        return "one:" + str(event_data.get("message", ""));
    }

    def _boom(event_data: dict, ctx: any) -> str {
        order.append("boom");
        raise ValueError("listener failed");
    }

    def _h3(event_data: dict, ctx: any) -> str {
        order.append("h3");
        return "three";
    }

    register_fake_listener(bridge, "turn_start", _h1);
    register_fake_listener(bridge, "turn_start", _boom);
    register_fake_listener(bridge, "turn_start", _h3);

    results = fire_hook(bridge, "turn_start", {"message": "hi"});
    assert order == ["h1", "boom", "h3"];
    assert len(results) == 3;
    assert results[0]["ok"] is True and results[0]["result"] == "one:hi";
    assert results[1]["ok"] is False and "listener failed" in results[1]["error"];
    assert results[2]["ok"] is True and results[2]["result"] == "three";

    # Unregistered event returns empty results (best-effort, never fatal).
    assert fire_hook(bridge, "unknown_event", {}) == [];
}


test "unload_extension drops bridge commands for the extension" {
    bridge = create_bridge("s-unload");
    reg = create_registry();
    load_extension(bridge, reg, "x.tools", [], {});

    def _xcmd(args: str, ctx: any) -> str {
        return str(args);
    }

    register_fake_command(bridge, "xcmd", _xcmd, extension_id="x.tools");
    register_fake_command(bridge, "ycmd", _xcmd, extension_id="y.tools");
    unload_extension(bridge, reg, "x.tools");
    assert "xcmd" not in bridge.commands;
    assert "ycmd" in bridge.commands;
}


test "node host loads stub_commands fixture: commands tracked, cmd_invoke round-trips" {
    bridge = create_bridge("s-t2-node");
    reg = create_registry();
    ensure_node_host(bridge);
    path = resolve_stub_commands();
    names = load_extension_path(bridge, reg, "stub.commands", path);
    assert names == [];
    assert "upper" in bridge.commands;
    assert bridge.commands["upper"]["description"] == "Uppercase the given args";

    res = invoke_command(bridge, "upper", "hello t2");
    assert res["ok"] is True;
    assert res["result"] == "HELLO T2";
    assert res.get("notifications") == ["UPPER:HELLO T2"];

    missing = invoke_command(bridge, "missing_cmd", "");
    assert missing["ok"] is False;

    dispose_bridge(bridge);
}


test "node host fires lifecycle hooks through the bridge" {
    bridge = create_bridge("s-t2-hook");
    reg = create_registry();
    ensure_node_host(bridge);
    path = resolve_stub_commands();
    load_extension_path(bridge, reg, "stub.commands", path);

    results = fire_hook(bridge, "turn_start", {"message": "m1"});
    assert len(results) == 1;
    assert results[0]["ok"] is True;
    assert results[0]["result"] == "ts:m1";
    assert results[0]["extension_id"] == "stub.commands";

    # No listeners on this event -> empty result list.
    assert fire_hook(bridge, "session_shutdown", {}) == [];

    dispose_bridge(bridge);
}


# ===================== T2b: markdown transformers =====================

test "fake host transformer chain runs in order and isolates errors" {
    bridge = create_bridge("s-xform");
    reg = create_registry();

    def _wrap_a(md: str, ctx: any) -> str {
        return "a(" + str(md) + ")";
    }

    def _boom(md: str, ctx: any) -> str {
        raise ValueError("xform failed");
    }

    def _wrap_c(md: str, ctx: any) -> str {
        return "c[" + str(md) + "]";
    }

    register_fake_transformer(bridge, _wrap_a, extension_id="e1");
    register_fake_transformer(bridge, _boom, extension_id="e2");
    register_fake_transformer(bridge, _wrap_c, extension_id="e3");

    res = transform_markdown(bridge, "hi");
    assert res["ok"] is True;
    # a applied, boom kept prior output, c wrapped the result.
    assert res["markdown"] == "c[a(hi)]";

    # Non-string returns keep prior output (chain from above still active).
    def _none(md: str, ctx: any) -> any {
        return 42;
    }
    register_fake_transformer(bridge, _none);
    res2 = transform_markdown(bridge, "x");
    assert res2["markdown"] == "c[a(x)]";

    # Unload purges owned transformers.
    unload_extension(bridge, reg, "e1");
    res3 = transform_markdown(bridge, "hi");
    assert res3["markdown"] == "c[hi]";

    # Passthrough without a host.
    empty = create_bridge("s-xform-none");
    res4 = transform_markdown(empty, "raw");
    assert res4 == {"ok": True, "markdown": "raw"};
}


test "node host transforms markdown through the bridge" {
    bridge = create_bridge("s-t2b-node");
    reg = create_registry();
    ensure_node_host(bridge);
    load_extension_path(bridge, reg, "stub.commands", resolve_stub_commands());

    res = transform_markdown(
        bridge, "code:\n```py\nx=1\n```", message_type="assistant"
    );
    assert res["ok"] is True;
    # stub_commands replaces ``` with ≡≡≡ (display-only chain over the wire).
    assert "≡≡≡" in res["markdown"];
    assert "```" not in res["markdown"];

    # No transformers registered on this event path -> identity.
    bare = create_bridge("s-t2b-bare");
    ensure_node_host(bare);
    res2 = transform_markdown(bare, "plain");
    assert res2 == {"ok": True, "markdown": "plain"};

    dispose_bridge(bare);
    dispose_bridge(bridge);
}


# ===================== B1: extension traffic + control =====================

test "fake host drains messages entries and ui events" {
    bridge = create_bridge("s-b1");
    reg = create_registry();

    def _spill(args: str, ctx: any) -> str {
        ctx["ui"].set_title("t1");
        ctx["ui"].set_widget("w", "x");
        return "spilled";
    }

    register_fake_command(bridge, "spill", _spill);
    res = invoke_command(bridge, "spill", "");
    assert res["ok"] is True;
    assert res["ui_events"][0]["method"] == "setTitle";
    assert res["ui_events"][1]["method"] == "setWidget";

    fake_push_message(bridge, "assistant", "pushed note");
    fake_push_entry(bridge, "note", {"k": "v"});
    traffic = drain_extension_traffic(bridge);
    assert traffic["messages"] == [{"role": "assistant", "content": "pushed note"}];
    assert len(traffic["entries"]) == 3;
    # Entries include the ui_event normalized from the command's UI calls.
    entries: list[dict] = list(traffic["entries"]);
    kinds: list[str] = [];
    for entry in entries {
        kinds.append(str(entry.get("type", "")));
    }
    assert "ui_event" in kinds;

    # Drain clears.
    traffic2 = drain_extension_traffic(bridge);
    assert traffic2 == {"messages": [], "entries": []};
}


test "fake host enforces active tools" {
    bridge = create_bridge("s-b1-active");
    reg = create_registry();

    def _noop() -> str {
        return "ok";
    }

    names = load_extension(
        bridge,
        reg,
        "b1.tools",
        [{"name": "t_only", "description": "probe", "parameters": {"type": "object", "properties": {}}}],
        {"t_only": _noop},
    );

    set_fake_active_tools(bridge, ["other_tool"]);
    r1 = invoke(reg, "t_only", {}, bridge);
    assert r1.startswith("ERROR:") and "not active" in r1;

    set_fake_active_tools(bridge, None);
    r2 = invoke(reg, "t_only", {}, bridge);
    assert not r2.startswith("ERROR:");
}


test "session name round-trips on the bridge" {
    bridge = create_bridge("s-b1-name");
    ok = set_session_name(bridge, "my-session");
    assert ok is True;
    assert fake_session_name(bridge) == "my-session";
}
