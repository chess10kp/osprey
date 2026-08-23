"""Tests for agent/llm.jac (same-stem annex, merged with the base module
at test time - no import of the own stem). Covers the ReAct loop: tool runs,
transient retries, cooperative cancel, loop limits, approval hooks, request
body shape, provider transport binding, registry/js tools, and plugin-bridge
tool_call block verdicts.

Test-only transports and helpers live here, not in llm.jac.
"""


obj RetryTransport {
    has calls: int = 0;

    def stream(messages: list, tool_defs: list) -> Generator[dict, None, None] {
        self.calls += 1;
        if self.calls == 1 {
            yield {"error": "HTTP 503: temporarily unavailable"};
        } else {
            yield {"content": "recovered"};
        }
    }
}


obj TwoCallTransport {
    def stream(messages: list, tool_defs: list) -> Generator[dict, None, None] {
        saw = False;
        for m in messages {
            msg: any = m;
            if msg.get("role") == "tool" { saw = True; }
        }
        if not saw {
            yield {"content": "working"};
            yield {"tool_calls": [
                {
                    "id": "call_1",
                    "type": "function",
                    "function": {"name": "echo", "arguments": "{\"text\": \"one\"}"},
                },
                {
                    "id": "call_2",
                    "type": "function",
                    "function": {"name": "echo", "arguments": "{\"text\": \"two\"}"},
                },
            ]};
        } else {
            yield {"content": "done"};
        }
    }
}


obj ScriptedTransport {
    has tool_call_id: str = "call_1",
        tool_name: str = "echo",
        tool_args: str = "{\"text\": \"hi\"}",
        final_text: str = "done";

    def stream(messages: list, tool_defs: list) -> Generator[dict, None, None] {
        saw_tool_result = False;
        for m in messages {
            msg: any = m;
            if msg.get("role") == "tool" { saw_tool_result = True; }
        }
        if not saw_tool_result {
            yield {"content": "let me check"};
            yield {"tool_calls": [{
                "id": self.tool_call_id,
                "type": "function",
                "function": {"name": self.tool_name, "arguments": self.tool_args},
            }]};
        } else {
            yield {"content": self.final_text};
        }
    }
}

def _echo(text: str) -> str {
    return "ECHO:" + text;
}

def _noop_event(kind: str, data: dict) {
    _events.append([kind, dict(data)]);
}

glob _events: list = [];


test "react loop runs a tool then finishes" {
    messages = [{"role": "user", "content": "echo hi"}];
    specs = [ToolSpec(
        name="echo",
        description="echo the text",
        parameters={"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]},
        handler=_echo,
    )];
    _events.clear();
    answer = react_loop(messages, specs, ScriptedTransport(), _noop_event);
    assert answer == "done";
    kinds = [e[0] for e in _events];
    assert kinds == [
        "chunk", "approval_request", "approval_decision",
        "tool_call", "tool_result", "chunk",
    ];
    tc = _events[3][1];
    assert tc["tool"] == "echo" and tc["args"] == {"text": "hi"};
    tr = _events[4][1];
    assert tr["result"] == "ECHO:hi";
    roles = [m["role"] for m in messages];
    assert roles == ["user", "assistant", "tool", "assistant"];
    assert messages[2]["tool_call_id"] == "call_1";
}


test "react loop retries transient transport errors" {
    messages = [{"role": "user", "content": "hello"}];
    _events.clear();
    transport = RetryTransport();
    answer = react_loop(messages, [], transport, _noop_event, max_retries=1);
    assert answer == "recovered";
    assert transport.calls == 2;
    assert _events[0][0] == "retry";
    assert _events[1][0] == "chunk";
}


obj CancelMidStreamTransport {
    has flag: any = None;

    def stream(messages: list, tool_defs: list) -> Generator[dict, None, None] {
        yield {"content": "partial"};
        if self.flag is not None {
            self.flag.cancelled = True;
        }
        yield {"content": " never seen"};
    }
}


test "react loop stops mid-stream on cancel without touching history" {
    messages = [{"role": "user", "content": "hello"}];
    _events.clear();
    cancel = TurnCancel();
    transport = CancelMidStreamTransport(flag=cancel);
    answer = react_loop(messages, [], transport, _noop_event, cancel=cancel);
    assert answer == "partial";
    assert len(messages) == 1;
    kinds = [e[0] for e in _events];
    assert kinds == ["chunk", "cancelled"];
    assert _events[1][1]["phase"] == "streaming";
}


test "cancel before tool calls fills cancelled tool results" {
    messages = [{"role": "user", "content": "echo hi"}];
    specs = [ToolSpec(
        name="echo",
        description="echo",
        parameters={"type": "object", "properties": {"text": {"type": "string"}}},
        handler=_echo,
    )];
    _events.clear();
    cancel = TurnCancel();
    transport = TwoCallTransport();

    # Cooperative semantics: the in-flight call finishes; the NEXT pending
    # call is skipped and filled with a terminal cancelled result.
    def _cancelling_event(kind: str, data: dict) {
        _events.append([kind, dict(data)]);
        if kind == "tool_result" {
            cancel.cancelled = True;
        }
    }

    answer = react_loop(messages, specs, transport, _cancelling_event, cancel=cancel);
    assert answer == "done" or answer == "working";
    roles = [m["role"] for m in messages];
    assert roles == ["user", "assistant", "tool", "tool"];
    # First call ran; second was filled with the cancelled marker.
    assert messages[2]["content"] == "ECHO:one";
    assert messages[3]["content"] == "ERROR: cancelled by user";
    assert _events[-1][0] == "cancelled";
    assert _events[-1][1]["phase"] == "tool";
}


def _deny_all(name: str, args: dict) -> any {
    return "denied by test policy";
}


def _allow_all(name: str, args: dict) -> any {
    return True;
}


test "approve hook denial yields error tool result without executing" {
    messages = [{"role": "user", "content": "echo hi"}];
    specs = [ToolSpec(
        name="echo",
        description="echo",
        parameters={"type": "object", "properties": {"text": {"type": "string"}}},
        handler=_echo,
    )];
    _events.clear();
    answer = react_loop(messages, specs, ScriptedTransport(), _noop_event, approve=_deny_all);
    # The loop continues past a denial — the model sees the ERROR result
    # and produces a final answer.
    roles = [m["role"] for m in messages];
    assert roles == ["user", "assistant", "tool", "assistant"];
    assert messages[2]["content"].startswith("ERROR:");
    assert "denied by test policy" in messages[2]["content"];
    # No echo ran; the request + denial pair is on the event stream.
    kinds = [e[0] for e in _events];
    assert "approval_request" in kinds and "approval_decision" in kinds;
    idx_req = kinds.index("approval_request");
    assert _events[idx_req][1]["tool"] == "echo";
}

test "approve hook allow runs the tool unchanged" {
    messages = [{"role": "user", "content": "echo hi"}];
    specs = [ToolSpec(
        name="echo",
        description="echo",
        parameters={"type": "object", "properties": {"text": {"type": "string"}}},
        handler=_echo,
    )];
    _events.clear();
    answer = react_loop(messages, specs, ScriptedTransport(), _noop_event, approve=_allow_all);
    assert messages[2]["content"] == "ECHO:hi";
}


test "react loop emits loop limit" {
    messages = [{"role": "user", "content": "echo"}];
    specs = [ToolSpec(
        name="echo",
        description="echo the text",
        parameters={"type": "object", "properties": {"text": {"type": "string"}}},
        handler=_echo,
    )];
    _events.clear();
    answer = react_loop(messages, specs, ScriptedTransport(), _noop_event, max_iters=1);
    assert answer == "";
    assert _events[-1][0] == "loop_limit";
    assert _events[-1][1]["max_iters"] == 1;
}


test "tool defs are openai function shape" {
    specs = [ToolSpec(name="x", description="d", parameters={"type": "object", "properties": {}}, handler=_echo)];
    defs = _tool_defs(specs);
    assert defs[0]["type"] == "function";
    assert defs[0]["function"]["name"] == "x";
    assert defs[0]["function"]["parameters"]["type"] == "object";
}


test "request body omits reasoning when thinking unset" {
    t = Transport(model="test-model");
    assert t._build_body([], []) == {
        "model": "test-model",
        "messages": [],
        "stream": True,
    };
}


test "request body carries reasoning effort when thinking set" {
    t = Transport(model="test-model", thinking="high");
    assert t._build_body([{"role": "user", "content": "hi"}], [{"type": "function"}]) == {
        "model": "test-model",
        "messages": [{"role": "user", "content": "hi"}],
        "stream": True,
        "tools": [{"type": "function"}],
        "reasoning": {"effort": "high"},
    };
    for level in ["off", "minimal", "low", "medium", "high"] {
        t.thinking = level;
        body = t._build_body([], []);
        assert body["reasoning"] == {"effort": level};
    }
}


test "make_transport binds explicit model and thinking per provider" {
    tr = make_transport("openrouter/vendor/model-x", thinking="medium");
    assert tr.base_url == "https://openrouter.ai/api/v1";
    assert tr.model == "vendor/model-x";
    assert tr.thinking == "medium";
    assert tr._build_body([], [])["model"] == "vendor/model-x";

    ds = make_transport("deepseek/deepseek-chat", thinking="low");
    assert ds.model == "deepseek-chat";
    assert ds.thinking == "low";

    plain = make_transport("gpt-4o-mini", thinking="minimal");
    assert plain.model == "gpt-4o-mini";
    assert plain.thinking == "minimal";

    # Backward-compat shapes: no thinking arg, default model arg.
    legacy = make_transport("legacy-model");
    assert legacy.thinking == "";
    assert "reasoning" not in legacy._build_body([], []);
    defaulted = make_transport();
    assert defaulted.model == "";
}


test "unknown tool yields error result without crashing" {
    messages = [{"role": "user", "content": "go"}];
    spec = ScriptedTransport();
    spec.tool_name = "missing";
    _events.clear();
    answer = react_loop(messages, [], spec, _noop_event);
    assert "unknown tool" in _events[4][1]["result"];
    assert messages[2]["content"].startswith("ERROR");
}


test "react loop invokes js tool via registry bridge" {
    import from .registry { create_registry }
    import from .plugin_bridge {
        create_bridge,
        load_extension,
        dispose_bridge,
    }

    def _js_echo(text: str) -> str {
        return "JS:" + text;
    }

    messages = [{"role": "user", "content": "echo hi"}];
    reg = create_registry();
    bridge = create_bridge("react-js");
    load_extension(
        bridge,
        reg,
        "stub.echo",
        [{
            "name": "echo",
            "description": "echo via js",
            "parameters": {
                "type": "object",
                "properties": {"text": {"type": "string"}},
                "required": ["text"],
            },
        }],
        {"echo": _js_echo},
    );
    transport = ScriptedTransport();
    transport.tool_name = "echo";
    transport.tool_args = "{\"text\": \"hi\"}";
    _events.clear();
    answer = react_loop(messages, [], transport, _noop_event, reg=reg, bridge=bridge);
    assert answer == "done";
    assert _events[4][1]["result"] == "JS:hi";
    dispose_bridge(bridge);
}


test "react loop honors tool_call block verdicts from a plugin bridge" {
    import from .plugin_bridge {
        create_bridge,
        dispose_bridge,
    }
    import from .fake_host {
        ensure_host,
        register_fake_listener,
    }
    import from .registry { create_registry }

    def _block_no_terminate(data: dict, ctx: any) -> dict {
        return {"block": True, "reason": "policy"};
    }

    messages = [{"role": "user", "content": "run echo"}];
    reg = create_registry();
    bridge = create_bridge("react-gate");
    ensure_host(bridge);
    register_fake_listener(bridge, "tool_call", _block_no_terminate);
    transport = ScriptedTransport();
    transport.tool_name = "echo";
    _events.clear();
    answer = react_loop(messages, [], transport, _noop_event, reg=reg, bridge=bridge);
    # Blocked call becomes an error tool-result; the run continues normally.
    assert answer == "done";
    assert messages[2]["role"] == "tool";
    assert messages[2]["content"] == "ERROR: blocked by extension: policy";
    dispose_bridge(bridge);
}


test "react loop stops early on terminating block verdict" {
    import from .plugin_bridge {
        create_bridge,
        dispose_bridge,
    }
    import from .fake_host {
        ensure_host,
        register_fake_listener,
    }
    import from .registry { create_registry }

    def _terminate_block(data: dict, ctx: any) -> dict {
        return {"block": True, "reason": "dangerous command", "terminate": True};
    }

    messages = [{"role": "user", "content": "run echo"}];
    reg = create_registry();
    bridge = create_bridge("react-term");
    ensure_host(bridge);
    register_fake_listener(bridge, "tool_call", _terminate_block);
    transport = ScriptedTransport();
    transport.tool_name = "echo";
    _events.clear();
    answer = react_loop(messages, [], transport, _noop_event, reg=reg, bridge=bridge);
    assert answer == "";
    assert messages[-1]["content"] == "ERROR: blocked by extension: dangerous command";
    kinds = [e[0] for e in _events];
    assert "error" in kinds;
    dispose_bridge(bridge);
}


test "make_ext_transport wires provider config without network" {
    import from .plugin_bridge {
        create_bridge,
        dispose_bridge,
    }
    import from .fake_host {
        register_fake_provider,
    }

    bridge = create_bridge("p10-transport");
    register_fake_provider(bridge, {
        "name": "acme",
        "models": ["sonnet-x"],
        "base_url": "https://acme.example/v1",
    });

    t = make_ext_transport(bridge as PluginBridge, "ext/fake.provider/sonnet-x");
    assert t is not None;
    assert t.base_url == "https://acme.example/v1";
    assert t.model == "sonnet-x";
    assert t.ext_cfg["provider"] == "acme";

    # Unknown / non-ext ids fall back to None (native routing).
    assert make_ext_transport(bridge as PluginBridge, "gpt-4o") is None;
    assert make_ext_transport(bridge as PluginBridge, "ext/ghost/m") is None;
    assert make_ext_transport(None, "ext/a/b") is None;
    dispose_bridge(bridge);
}


test "react loop applies tool_result rewrites from a plugin bridge" {
    import from .plugin_bridge {
        PluginBridge,
        create_bridge,
        ensure_host,
        register_fake_listener,
        load_extension,
        dispose_bridge,
    }
    import from .registry { create_registry, ToolRegistry }

    def _rewrite(data: dict, ctx: any) -> dict {
        # Sees the latest content; appends a marker (middleware chain).
        if data.get("toolName") == "echo" {
            return {"content": str(data.get("content", "")) + "+REWRITTEN"};
        }
        return None;
    }

    def _confirm_latest(data: dict, ctx: any) -> dict {
        # Second handler must see the first handler's patch applied.
        assert str(data.get("content", "")).endswith("+REWRITTEN");
        return None;
    }

    messages = [{"role": "user", "content": "run echo"}];
    reg = create_registry();
    bridge = create_bridge("react-tres");
    ensure_host(bridge);
    register_fake_listener(bridge as PluginBridge, "tool_result", _rewrite);
    register_fake_listener(bridge as PluginBridge, "tool_result", _confirm_latest);
    load_extension(
        bridge as PluginBridge,
        reg as ToolRegistry,
        "stub.echo",
        [{
            "name": "echo",
            "description": "echo",
            "parameters": {"type": "object", "properties": {"text": {"type": "string"}}},
        }],
        {"echo": _echo},
    );
    transport = ScriptedTransport();
    transport.tool_name = "echo";
    transport.tool_args = "{\"text\": \"hi\"}";
    _events.clear();
    answer = react_loop(messages, [], transport, _noop_event, reg=reg, bridge=bridge);
    assert answer == "done";
    # Module-level _echo prefixes ECHO:; the middleware appends +REWRITTEN.
    assert messages[2]["content"] == "ECHO:hi+REWRITTEN";
    dispose_bridge(bridge);
}


test "react loop skips tool execution when cancelled during the gate" {
    import from .plugin_bridge {
        PluginBridge,
        create_bridge,
        ensure_host,
        register_fake_listener,
        load_extension,
        dispose_bridge,
    }
    import from .registry { create_registry }

    # TurnCancel is module-level in this file.
    cancel = TurnCancel();

    def _slow_gate(data: dict, ctx: any) -> any {
        # User hits esc while the gate dialog is open.
        cancel.cancelled = True;
        return None;
    }

    messages = [{"role": "user", "content": "run echo"}];
    reg = create_registry();
    bridge = create_bridge("react-cancel-gate");
    ensure_host(bridge);
    register_fake_listener(bridge as PluginBridge, "tool_call", _slow_gate);
    load_extension(
        bridge as PluginBridge,
        reg as ToolRegistry,
        "stub.echo",
        [{
            "name": "echo",
            "description": "echo",
            "parameters": {"type": "object", "properties": {"text": {"type": "string"}}},
        }],
        {"echo": _echo},
    );
    transport = ScriptedTransport();
    transport.tool_name = "echo";
    _events.clear();
    answer = react_loop(messages, [], transport, _noop_event, reg=reg, bridge=bridge, cancel=cancel);
    # The gate fired; the tool itself must NOT have executed. Cancelled
    # calls get a terminal tool MESSAGE but no tool_result event (matching
    # the pre-existing cancel-before-invoke semantics).
    assert messages[2]["role"] == "tool";
    assert messages[2]["content"] == "ERROR: cancelled by user";
    assert len(messages) == 3;  # no assistant reply after abort
    dispose_bridge(bridge);
}
