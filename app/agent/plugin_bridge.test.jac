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
    register_native,
}
import from .protocol {
    is_plugin_kind,
    is_ui_kind,
    make_plugin_envelope,
}
import from .fake_host {
    register_fake_command,
    register_fake_shortcut,
    register_fake_listener,
    register_fake_transformer,
    register_fake_provider,
    register_fake_renderer,
    fake_push_message,
    fake_push_entry,
    set_fake_active_tools,
    fake_session_name,
}


def _echo(text: str) -> str {
    return "JS:" + text;
}


"""Checker shim: the Jac type checker cannot bind AnyStr when a plain str
flows into os.path.dirname (same pattern as auth.jac / checkpoints.jac)."""
def _path_dirname(p: str) -> str {
    fn: any = os.path.dirname;
    return str(fn(p));
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
    # "events" is still a stubbed surface (P11 promoted renderers+providers
    # to real caps; events remains local-only by design).
    raised = False;
    try {
        load_extension_path(
            bridge, reg, "stub.echo", stub, requires=["events"]
        );
    } except RuntimeError {
        raised = True;
    }
    assert raised;

    # "renderers" is now a REAL cap — must load cleanly.
    names = load_extension_path(
        bridge, reg, "stub.echo", stub, requires=["renderers"]
    );
    assert "echo" in names;
    dispose_bridge(bridge);
}


test "tool_cancel aborts slow Pi tool" {
    bridge = create_bridge("s-cancel");
    reg = create_registry();
    ensure_node_host(bridge);
    host = resolve_host_mjs();
    slow = os.path.join(_path_dirname(str(host)), "fixtures", "pi_slow.mjs");
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


test "fake host shortcut invoke fires handler with ui ctx" {
    bridge = create_bridge("s-sc");

    fired: list[str] = [];

    def _toggle(ctx: any) -> str {
        ctx["ui"].notify("TOGGLED");
        fired.append("hit");
        return "plan mode on";
    }

    register_fake_shortcut(bridge, "ctrl+shift+p", _toggle, description="Toggle plan");
    assert bridge.shortcuts["ctrl+shift+p"]["extension_id"] == "fake.shortcuts";
    assert bridge.shortcuts["ctrl+shift+p"]["description"] == "Toggle plan";

    res = invoke_shortcut(bridge, "ctrl+shift+p");
    assert res["ok"] is True;
    assert res["result"] == "plan mode on";
    assert res["notifications"] == ["TOGGLED"];
    assert len(fired) == 1;

    missing = invoke_shortcut(bridge, "ctrl+shift+z");
    assert missing["ok"] is False;
    assert "unknown shortcut" in missing["error"];
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


# ===================== batch-2 events + structured verdicts =====================

test "fire_hook_data fake path captures verdicts and chains mutations" {
    bridge = create_bridge("s-b2-data");
    ensure_host(bridge);

    def _mutator(data: dict, ctx: any) -> str {
        data["input"]["text"] = data["input"]["text"].upper();
        return "";
    }

    def _verdict(data: dict, ctx: any) -> dict {
        # Sees the mutation made by _mutator (in-place chaining).
        assert data["input"]["text"] == "HI";
        return {"block": True, "reason": "nope"};
    }

    register_fake_listener(bridge, "tool_call", _mutator);
    register_fake_listener(bridge, "tool_call", _verdict);

    fired = fire_hook_data(
        bridge, "tool_call", {"toolName": "echo_arg", "input": {"text": "hi"}}
    );
    results = fired["results"];
    final = fired["data"];
    assert len(results) == 2;
    assert results[0]["ok"] is True and results[0]["verdict"] is None;
    assert results[1]["verdict"] == {"block": True, "reason": "nope"};
    assert final["input"]["text"] == "HI";
    dispose_bridge(bridge);
}


test "tool_call_gate aggregates blocks and mutated args" {
    bridge = create_bridge("s-b2-gate");
    ensure_host(bridge);

    def _gate(data: dict, ctx: any) -> any {
        if str(data["input"].get("command", "")).find("rm") >= 0 {
            return {"block": True, "reason": "danger", "terminate": True};
        }
        if data.get("toolName") == "echo_arg" {
            data["input"]["text"] = "MUTATED";
        }
        return None;
    }

    register_fake_listener(bridge, "tool_call", _gate);

    g1 = tool_call_gate(bridge, "bash", {"command": "rm -rf /"});
    assert g1["blocked"] is True;
    assert g1["reason"] == "danger";
    assert g1["terminate"] is True;

    g2 = tool_call_gate(bridge, "echo_arg", {"text": "orig"});
    assert g2["blocked"] is False;
    assert g2["args"]["text"] == "MUTATED";

    # No bridge -> pass-through with original args.
    g3 = tool_call_gate(None, "bash", {"command": "ls"});
    assert g3["blocked"] is False and g3["args"] == {"command": "ls"};
    dispose_bridge(bridge);
}


test "input_gate handles and transforms" {
    bridge = create_bridge("s-b2-input");
    ensure_host(bridge);

    def _input(data: dict, ctx: any) -> any {
        t = str(data.get("text", ""));
        if t == "!gate" {
            return {"action": "handled"};
        }
        if t.startswith("?up ") {
            return {"action": "transform", "text": t[4:].upper()};
        }
        return None;
    }

    register_fake_listener(bridge, "input", _input);
    r1 = input_gate(bridge, "!gate");
    assert r1["action"] == "handled";
    r2 = input_gate(bridge, "?up hello");
    assert r2["action"] == "transform" and r2["text"] == "HELLO";
    r3 = input_gate(bridge, "plain");
    assert r3["action"] == "continue";
    assert input_gate(None, "x")["action"] == "continue";
    dispose_bridge(bridge);
}


test "input transforms chain across handlers on the fake host" {
    bridge = create_bridge("s-b2-chain");
    ensure_host(bridge);

    def _first(data: dict, ctx: any) -> dict | None {
        t = str(data.get("text", ""));
        if t.startswith("?up ") {
            return {"action": "transform", "text": t[4:].upper()};
        }
        return None;
    }

    def _second(data: dict, ctx: any) -> dict | None {
        # Sees the REWRITTEN text from _first (chaining parity pin).
        t = str(data.get("text", ""));
        if t and t == t.upper() and any(c.isupper() for c in t) {
            return {"action": "transform", "text": t + "-CHAINED"};
        }
        return None;
    }

    register_fake_listener(bridge, "input", _first);
    register_fake_listener(bridge, "input", _second);
    r = input_gate(bridge, "?up hi");
    assert r["action"] == "transform";
    assert r["text"] == "HI-CHAINED";
    dispose_bridge(bridge);
}


test "context_gate applies in-place edits and replacements non-destructively" {
    bridge = create_bridge("s-b2-ctx");
    ensure_host(bridge);

    def _ctx_edit(data: dict, ctx: any) -> any {
        data["messages"].append({"role": "user", "content": "[inject]"});
        return None;
    }

    def _ctx_replace(data: dict, ctx: any) -> dict {
        return {"messages": [{"role": "user", "content": "replaced"}]};
    }

    history = [{"role": "user", "content": "hi"}];
    register_fake_listener(bridge, "context", _ctx_edit);
    out1 = context_gate(bridge, history);
    assert len(out1) == 2;
    assert out1[1]["content"] == "[inject]";
    assert len(history) == 1;  # caller history untouched

    h_reset = bridge.host;
    if h_reset is not None {
        h_reset.listeners["context"] = [];
    }
    register_fake_listener(bridge, "context", _ctx_replace);
    out2 = context_gate(bridge, history);
    assert out2 == [{"role": "user", "content": "replaced"}];

    assert context_gate(None, history) is history;
    dispose_bridge(bridge);
}


test "agent_start_gate collects systemPrompt and message" {
    bridge = create_bridge("s-b2-agent");
    ensure_host(bridge);

    def _sys(data: dict, ctx: any) -> dict {
        return {"systemPrompt": data["prompt"] + "+sys", "message": {"content": "extra ctx"}};
    }

    register_fake_listener(bridge, "before_agent_start", _sys);
    a = agent_start_gate(bridge, "prompt");
    assert a["systemPrompt"] == "prompt+sys";
    assert a["message"] == "extra ctx";
    assert agent_start_gate(None, "p") == {"message": "", "systemPrompt": ""};
    dispose_bridge(bridge);
}


test "node host echoes structured verdicts and mutated working data" {
    bridge = create_bridge("s-b2-node");
    reg = create_registry();
    ensure_node_host(bridge);
    gated = resolve_pi_gated();
    names = load_extension_path(bridge, reg, "pi.gated", gated);
    drain_inbox(bridge);

    # tool_call block verdict + terminate flag.
    g = tool_call_gate(bridge, "bash", {"command": "rm -rf /tmp/x"});
    assert g["blocked"] is True;
    assert g["reason"] == "dangerous command";
    assert g["terminate"] is True;

    # tool_call in-place input mutation echoed back through hook_done.data.
    g2 = tool_call_gate(bridge, "echo_arg", {"text": "hi"});
    assert g2["blocked"] is False;
    assert g2["args"]["text"] == "HI";

    # context in-place message edit echoed back.
    msgs = [{"role": "user", "content": "q"}];
    out = context_gate(bridge, msgs);
    assert out[-1]["content"] == "[gated-context-injection]";
    assert len(msgs) == 1;

    # input verdicts.
    i1 = input_gate(bridge, "!gate");
    assert i1["action"] == "handled";
    i2 = input_gate(bridge, "?upper shout");
    # Fixture chains a second input handler that appends -CHAINED to
    # all-caps text — proves shim-side transform chaining reaches us.
    assert i2["action"] == "transform" and i2["text"] == "SHOUT-CHAINED";

    # before_agent_start systemPrompt verdict.
    a = agent_start_gate(bridge, "hello");
    assert a["systemPrompt"] == "\n[gated-system-append]";

    dispose_bridge(bridge);
}


# ============================ P10: provider seam ============================

test "register_fake_provider feeds resolve_ext_model" {
    bridge = create_bridge("s-p10-fake");
    register_fake_provider(bridge, {
        "name": "acme",
        "models": ["sonnet-x", {"id": "opus-y", "name": "Opus Y"}],
        "base_url": "https://acme.example/v1",
    });

    c1 = resolve_ext_model(bridge, "ext/fake.provider/sonnet-x");
    assert c1 is not None;
    assert c1["provider"] == "acme";
    assert c1["model"] == "sonnet-x";
    assert c1["base_url"] == "https://acme.example/v1";
    assert c1["streaming"] is True;

    c2 = resolve_ext_model(bridge, "ext/fake.provider/opus-y");
    assert c2 is not None and c2["model"] == "opus-y";

    # Namespace mismatches -> None.
    assert resolve_ext_model(bridge, "native/gpt") is None;
    assert resolve_ext_model(bridge, "ext/ghost/model") is None;
    assert resolve_ext_model(None, "ext/a/b") is None;
    dispose_bridge(bridge);
}


test "prepare_provider_request applies edits and replacements" {
    bridge = create_bridge("s-p10-prep");
    ensure_host(bridge);

    def _mutator(data: dict, ctx: any) -> any {
        data["body"]["injected"] = True;
        return None;
    }

    def _replacer(data: dict, ctx: any) -> dict {
        return {"url": "https://proxy.example/v1/chat/completions"};
    }

    register_fake_listener(bridge, "before_provider_request", _mutator);
    register_fake_listener(bridge, "before_provider_request", _replacer);

    out = prepare_provider_request(
        bridge,
        "sonnet-x",
        "https://api.openai.com/v1/chat/completions",
        {"Authorization": "Bearer k"},
        {"model": "sonnet-x", "messages": []},
    );
    assert out["body"].get("injected") is True;
    assert out["url"] == "https://proxy.example/v1/chat/completions";
    assert out["headers"]["Authorization"] == "Bearer k";

    # No bridge -> identity passthrough.
    plain = prepare_provider_request(None, "m", "u", {}, {});
    assert plain == {"url": "u", "headers": {}, "body": {}};
    dispose_bridge(bridge);
}


test "node host ext_loaded carries providers and unload drops them" {
    bridge = create_bridge("s-p10-node");
    reg = create_registry();
    ensure_node_host(bridge);
    prov = resolve_host_mjs();
    path = os.path.join(_path_dirname(prov), "fixtures", "pi_provider.mjs");
    names = load_extension_path(bridge, reg, "pi.provider", path);
    drain_inbox(bridge);

    assert "acme" in bridge.providers;
    cfg = bridge.providers["acme"];
    assert cfg.get("extension_id") == "pi.provider";

    c1 = resolve_ext_model(bridge, "ext/pi.provider/sonnet-x");
    assert c1 is not None and c1["model"] == "sonnet-x";
    c2 = resolve_ext_model(bridge, "ext/pi.provider/opus-y");
    assert c2 is not None and c2["provider"] == "acme";

    # Unload drops the provider registrations.
    unload_extension(bridge, reg as ToolRegistry, "pi.provider");
    assert "acme" not in bridge.providers;
    assert resolve_ext_model(bridge, "ext/pi.provider/sonnet-x") is None;
    dispose_bridge(bridge);
}


# ============================ P11: renderers ============================

test "fake-host renderer normalizes to native content lines" {
    bridge = create_bridge("s-p11-fake");
    ensure_host(bridge);

    def _msg_renderer(message: any) -> any {
        return ["[acme] " + str(message)];
    }

    def _bad_renderer(payload: any) -> any {
        raise ValueError("boom");
    }

    def _usage_renderer(data: any) -> any {
        return {"lines": ["t:1"]};
    }

    register_fake_renderer(bridge, "message", "assistant", _msg_renderer);
    register_fake_renderer(bridge, "entry", "usage", _usage_renderer);
    register_fake_renderer(bridge, "entry", "broken", _bad_renderer);

    r1 = render_extension_block(bridge, "message", "assistant", "hello");
    assert r1["ok"] is True and r1["lines"] == ["[acme] hello"];

    r2 = render_extension_block(bridge, "entry", "usage", {});
    assert r2["ok"] is True and r2["lines"] == ["t:1"];

    # Renderer error degrades to unstyled fallback, never fails the turn.
    r3 = render_extension_block(bridge, "entry", "broken", "fallback");
    assert r3["ok"] is False;
    assert r3["lines"] == ["fallback"];

    # No renderer / no bridge.
    assert render_extension_block(bridge, "entry", "ghost", {})["ok"] is False;
    assert render_extension_block(None, "message", "assistant", "x")["ok"] is False;
    dispose_bridge(bridge);
}


test "node host renders message and entry blocks over the wire" {
    bridge = create_bridge("s-p11-node");
    reg = create_registry();
    ensure_node_host(bridge);
    prov = resolve_host_mjs();
    path = os.path.join(_path_dirname(prov), "fixtures", "pi_renderer.mjs");
    load_extension_path(bridge, reg, "pi.renderer", path);
    drain_inbox(bridge);

    r1 = render_extension_block(bridge, "message", "assistant", {"content": "hi"});
    assert r1["ok"] is True;
    assert r1["lines"] == ["[acme] hi"];

    r2 = render_extension_block(bridge, "entry", "usage", {"tokens": 5, "cost": "0.01"});
    assert r2["ok"] is True;
    assert r2["lines"][0] == "tokens: 5";

    # Unknown type on the wire path also degrades cleanly.
    r3 = render_extension_block(bridge, "message", "ghost", "x");
    assert r3["ok"] is False;

    # Unload drops owned renderers.
    unload_extension(bridge, reg as ToolRegistry, "pi.renderer");
    r4 = render_extension_block(bridge, "message", "assistant", {"content": "hi"});
    assert r4["ok"] is False;
    dispose_bridge(bridge);
}


# ===================== tool_result result-rewriting =====================

test "tool_result_gate chains patches and echoes latest content" {
    bridge = create_bridge("s-tres");
    ensure_host(bridge);

    def _first(data: dict, ctx: any) -> dict | None {
        if data.get("toolName") == "bash" {
            return {"content": str(data.get("content", "")) + "\n[redacted]"};
        }
        return None;
    }

    def _second(data: dict, ctx: any) -> dict {
        # Sees the first patch applied (middleware chaining pin).
        assert str(data.get("content", "")).endswith("[redacted]");
        return {"isError": True};
    }

    register_fake_listener(bridge as PluginBridge, "tool_result", _first);
    register_fake_listener(bridge as PluginBridge, "tool_result", _second);
    g = tool_result_gate(bridge, "bash", {"command": "ls"}, "out");
    assert g["ok"] is True;
    assert g["result"] == "out\n[redacted]";
    assert g["is_error"] is True;

    # No bridge -> identity.
    plain = tool_result_gate(None, "x", {}, "raw");
    assert plain == {"ok": True, "result": "raw", "is_error": False};
    dispose_bridge(bridge);
}


test "node host applies tool_result rewrites over the wire" {
    bridge = create_bridge("s-tres-node");
    reg = create_registry();
    ensure_node_host(bridge);
    gated = resolve_pi_gated();
    load_extension_path(bridge, reg, "pi.gated", gated);
    drain_inbox(bridge);

    g = tool_result_gate(bridge, "echo_arg", {"text": "hi"}, "ECHO:hi");
    assert g["ok"] is True;
    # Fixture appends the marker to successful echo_arg results.
    assert g["result"] == "ECHO:hi\n[gated-result-marker]";
    assert g["is_error"] is False;

    # Non-matching tools pass through untouched.
    g2 = tool_result_gate(bridge, "noop", {}, "ok");
    assert g2["result"] == "ok";
    dispose_bridge(bridge);
}


# ===================== kind-aware correlation (P12 prereq) =====================

test "interleaved sibling traffic does not wake or consume the wrong waiter" {
    bridge = create_bridge("s-kind");
    ensure_node_host(bridge);
    drain_inbox(bridge);

    corr = "corr-kind-test";
    _prepare_corr(bridge as PluginBridge, corr, expect_kind="tool_result");

    # A tool_update sharing the parent correlation arrives first.
    upd = make_plugin_envelope(
        kind="tool_update",
        payload={"text": "partial"},
        session_id=bridge.session_id,
        correlation_id=corr,
        tool_id="slow",
    );
    _dispatch_inbound(bridge as PluginBridge, upd);
    # Waiter must still be pending — not woken, not consumed.
    assert corr in bridge.pending;

    res = make_plugin_envelope(
        kind="tool_result",
        payload={"ok": True, "result": "final"},
        session_id=bridge.session_id,
        correlation_id=corr,
        tool_id="slow",
    );
    _dispatch_inbound(bridge as PluginBridge, res);
    waiter: any = bridge.pending.get(corr);
    assert waiter is not None and waiter["env"] is not None;
    assert waiter["env"].kind == "tool_result";
    dispose_bridge(bridge);
}


test "wait-time registration records expectation for direct callers" {
    bridge = create_bridge("s-kind2");
    ensure_host(bridge);
    # Simulate the historical race window: register bare, then wait.
    _prepare_corr(bridge as PluginBridge, "corr-k2", expect_kind="hook_done");
    junk = make_plugin_envelope(
        kind="tool_update",
        payload={"text": "noise"},
        session_id=bridge.session_id,
        correlation_id="corr-k2",
    );
    _dispatch_inbound(bridge as PluginBridge, junk);
    assert "corr-k2" in bridge.pending;
    dispose_bridge(bridge);
}


# ===================== P12 slice 2: interaction queue routing =====================

test "dispatch routes ui_request/ui_cancel into the interaction queue" {
    bridge = create_bridge("s-p12-route");
    ensure_host(bridge);
    assert bridge.interactive_ui is False;

    req = make_plugin_envelope(
        kind="ui_request",
        payload={
            "parent_correlation_id": "corr-9",
            "parent_kind": "cmd_invoke",
            "extension_id": "t.ext",
            "method": "select",
            "title": "pick",
            "options": ["a", "b"],
            "timeout_ms": 30000.0,
        },
        session_id=bridge.session_id,
        correlation_id="will-be-replaced",
    );
    _dispatch_inbound(bridge as PluginBridge, req);

    polled = poll_ui_request(bridge);
    assert polled is not None;
    assert polled["method"] == "select";
    assert polled["parent_corr"] == "corr-9";
    assert polled["options"] == ["a", "b"];

    # Answer it; queue drains and a second poll is None.
    assert respond_ui(bridge, polled["corr"], "a") is True;
    assert poll_ui_request(bridge) is None;
    # Idempotent answer to unknown corr.
    assert respond_ui(bridge, polled["corr"], "a") is False;

    # ui_cancel removes the pending request.
    req2 = make_plugin_envelope(
        kind="ui_request",
        payload={
            "parent_correlation_id": "corr-10",
            "method": "confirm",
            "message": "sure?",
            "timeout_ms": 30000.0,
        },
        session_id=bridge.session_id,
        correlation_id="child-2",
    );
    _dispatch_inbound(bridge as PluginBridge, req2);
    cancel_env = make_plugin_envelope(
        kind="ui_cancel",
        payload={"reason": "signal"},
        session_id=bridge.session_id,
        correlation_id="child-2",
    );
    _dispatch_inbound(bridge as PluginBridge, cancel_env);
    assert poll_ui_request(bridge) is None;
    dispose_bridge(bridge);
}


test "cancel_all_ui drains and expires auto-cancel" {
    bridge = create_bridge("s-p12-drain");
    ensure_host(bridge);
    for p in ["c1", "c2", "c3"] {
        env = make_plugin_envelope(
            kind="ui_request",
            payload={
                "parent_correlation_id": p,
                "method": "input",
                "placeholder": "x",
                "timeout_ms": 30000.0,
            },
            session_id=bridge.session_id,
            correlation_id=p,
        );
        _dispatch_inbound(bridge as PluginBridge, env);
    }
    n = cancel_all_ui(bridge, "turn-abort");
    assert n == 3;
    assert poll_ui_request(bridge) is None;
    assert cancel_all_ui(bridge, "again") == 0;

    # Expiry path: enqueue with a tiny timeout, poll after it lapses.
    import time;
    env2 = make_plugin_envelope(
        kind="ui_request",
        payload={
            "parent_correlation_id": "exp",
            "method": "input",
            "timeout_ms": 1.0,
        },
        session_id=bridge.session_id,
        correlation_id="exp-child",
    );
    _dispatch_inbound(bridge as PluginBridge, env2);
    time.sleep(0.05);
    got = poll_ui_request(bridge);
    assert got is None;  # expired -> answered cancelled, not surfaced
    dispose_bridge(bridge);
}

# ===================== T2c: execute ctx (builtins + ui) =====================

test "node host sends builtins on ext_load and getAllTools sees them" {
    bridge = create_bridge("s-t2-builtins");
    reg = create_registry();
    ensure_node_host(bridge);
    drain_inbox(bridge);
    # Seed a native builtin so the catalog is non-empty on the wire.
    register_native(reg, "read_file", "Read a file", {"type": "object", "properties": {}}, _echo);
    load_extension_path(bridge, reg, "ctx.probe", resolve_pi_ctx_probe());

    ctx_report = invoke(reg, "probe_ctx", {}, bridge);
    assert ctx_report.startswith("{");
    import json;
    data: dict = json.loads(ctx_report);
    assert data["has_cwd"] is True;
    assert data["ui_kind"] == "object";
    assert data["notify_kind"] == "function";
    assert data["select_kind"] == "function";
    # Builtins first, extension tools after — one flat catalog.
    assert data["tools"] == ["read_file", "probe_ctx", "probe_ui"];
    # Every ToolInfo carries Pi-shaped sourceInfo; extension tools point at
    # the fixture path, builtins at the synthetic jackal://builtin origin.
    assert data["source_info_count"] == 3;
    # Builtin coverage by count math: exactly one native builtin (read_file)
    # plus the two fixture tools are live, and ALL of them pass the fixture's
    # sourceInfo filter - so the builtin read_file is enriched too. Its own
    # field values ({path: "jackal://builtin", scope: "user",
    # origin: "package"} - pi_shim.mjs BUILTIN_SOURCE_INFO) are not exposed
    # per-tool by probe_ctx; asserting them would need a pi_shim-owned
    # fixture change, deliberately skipped here.
    assert len(data["tools"]) == 3;
    assert data["source_info_count"] == len(data["tools"]);
    assert data["probe_source"]["scope"] == "project";
    assert data["probe_source"]["origin"] == "top-level";
    assert "pi_ctx_probe.mjs" in str(data["probe_source"]["path"]);

    dispose_bridge(bridge);
}


test "tool execute ui ctx: notify rides tool_result notifications, setStatus rides ui_events" {
    bridge = create_bridge("s-t2-toolui");
    reg = create_registry();
    ensure_node_host(bridge);
    drain_inbox(bridge);
    load_extension_path(bridge, reg, "ctx.probe", resolve_pi_ctx_probe());

    res = invoke(reg, "probe_ui", {}, bridge);
    assert res == "ui exercised";

    # setStatus is a display method -> normalized ui_event entry.
    traffic: dict = drain_extension_traffic(bridge);
    methods: list[str] = [];
    entries: list = traffic["entries"];
    for entry in entries {
        row: dict = entry;
        if str(row.get("type", "")) == "ui_event" {
            methods.append(str(row.get("method", "")));
        }
    }
    assert methods == ["setStatus"];

    dispose_bridge(bridge);
}
