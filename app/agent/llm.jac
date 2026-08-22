"""Jackal model layer - owned ReAct loop, injectable transport. No byllm.

The transport is a swappable component (Cordis fiber candidate: provides
"llm.transport"). The loop is plain code we control end to end, so the
event stream here becomes the harness's UI protocol verbatim.

Transport contract: `stream(messages, tool_defs)` yields normalized chunk
dicts as they arrive:
    {"content": str}                          - one text token/fragment
    {"tool_calls": [ ...openai tool_call... ]} - complete calls, emitted once
    {"error": str}                            - transport-level failure
"""

import os;
import json;
import time;
import from typing { Callable, Generator }
import from .tool_spec { ToolSpec, MAX_TOOL_RESULT }
import from .registry {
    ToolRegistry,
    as_tool_specs,
    invoke,
}




obj Transport {
    has base_url: str = "https://api.openai.com/v1",
        api_key: str = "",
        model: str = "";

    def stream(messages: list, tool_defs: list) -> Generator[dict, None, None] {
        import httpx;
        body = {
            "model": self.model,
            "messages": messages,
            "stream": True,
        };
        if tool_defs { body["tools"] = tool_defs; }
        headers = {};
        if self.api_key { headers["Authorization"] = "Bearer " + self.api_key; }
        url = self.base_url.rstrip("/") + "/chat/completions";
        calls: dict[int, dict] = {};
        client_obj: any = httpx.Client(timeout=300.0);
        r: any = None;
        try {
            ctx: any = client_obj.stream("POST", url, json=body, headers=headers);
            r = ctx.__enter__();
            if r.status_code != 200 {
                detail = r.read().decode("utf-8", "replace")[:400];
                yield {"error": f"HTTP {r.status_code}: {detail}"};
                return;
            }
                for raw_line in r.iter_lines() {
                    line: any = raw_line;
                    if not line.startswith("data: ") { continue; }
                    payload: any = line[len("data: "):];
                    if payload == "[DONE]" { break; }
                    chunk: any = json.loads(payload);
                    delta: any = chunk["choices"][0].get("delta", {});
                    piece: any = delta.get("content");
                    if piece {
                        yield {"content": str(piece)};
                    }
                    for raw_tc in delta.get("tool_calls", []) {
                        tc: any = raw_tc;
                        idx = int(tc.get("index", 0));
                        acc = calls.get(idx);
                        if acc is None {
                            acc = {
                                "id": tc.get("id", ""),
                                "type": "function",
                                "function": {"name": "", "arguments": ""},
                            };
                            calls[idx] = acc;
                        }
                        fn: any = tc.get("function", {});
                        if fn.get("id") { acc["id"] = fn["id"]; }
                        if fn.get("name") {
                            acc["function"]["name"] = str(acc["function"]["name"]) + str(fn["name"]);
                        }
                        if fn.get("arguments") {
                            acc["function"]["arguments"] = str(acc["function"]["arguments"]) + str(fn["arguments"]);
                        }
                    }
                }
        } finally {
            if r is not None { r.close(); }
            client_obj.close();
        }
        if calls {
            ordered: list[dict] = [];
            for i in sorted(calls) { ordered.append(calls[i]); }
            yield {"tool_calls": ordered};
        }
    }
}


"""Pick a transport from the model name. Provider table lives here so the
whole model edge is one swappable module."""
def make_transport(model: str) -> Transport {
    if model.startswith("openrouter/") {
        return Transport(
            base_url="https://openrouter.ai/api/v1",
            api_key=os.environ.get("OPENROUTER_API_KEY", ""),
            model=model[len("openrouter/"):],
        );
    }
    if model.startswith("deepseek/") {
        return Transport(
            base_url="https://api.deepseek.com/v1",
            api_key=os.environ.get("DEEPSEEK_API_KEY", ""),
            model=model[len("deepseek/"):],
        );
    }
    return Transport(
        base_url=os.environ.get("OPENAI_COMPAT_BASE", "https://api.openai.com/v1"),
        api_key=os.environ.get("OPENAI_API_KEY", ""),
        model=model,
    );
}


def _tool_defs(specs: list[ToolSpec]) -> list {
    defs = [];
    for s in specs {
        defs.append({
            "type": "function",
            "function": {
                "name": s.name,
                "description": s.description,
                "parameters": s.parameters,
            },
        });
    }
    return defs;
}


def _find_spec(specs: list[ToolSpec], name: str) -> ToolSpec | None {
    for s in specs {
        if s.name == name { return s; }
    }
    return None;
}


def _is_transient_error(message: str) -> bool {
    lowered = message.lower();
    for marker in ["429", "500", "502", "503", "504", "timeout", "timed out", "connection", "temporarily unavailable"] {
        if marker in lowered { return True; }
    }
    return False;
}


def _cap_tool_result(result: any) -> str {
    text = str(result);
    if len(text) > MAX_TOOL_RESULT {
        return text[:MAX_TOOL_RESULT] + "\n... [tool result truncated]";
    }
    return text;
}


"""Drive the ReAct loop over `messages` IN PLACE (caller owns the history).

on_event(kind, data) fires as things happen:
  chunk       {"content"}          - live model token
  tool_call   {"tool", "args"}     - a call is about to run
  tool_result {"tool", "result"}   - a call finished (capped)
  retry      {"attempt", "max_retries", "message"}
  loop_limit {"max_iters", "iterations"}
  error      {"message"}
Returns the final assistant text.
"""
def react_loop(
    messages: list,
    specs: list[ToolSpec],
    transport: Transport,
    on_event: any,
    max_iters: int = 30,
    reg: ToolRegistry | None = None,
    bridge: any = None,
    max_retries: int = 2,
) -> str {
    # Prefer registry when provided so js-origin tools share one invoke path.
    active_specs = as_tool_specs(reg) if reg is not None else specs;
    defs = _tool_defs(active_specs);
    for turn in range(max_iters) {
        text = "";
        tool_calls: list = [];
        retries = 0;
        while True {
            stream_error = "";
            text = "";
            tool_calls = [];
            try {
                for chunk in transport.stream(messages, defs) {
                    c: any = chunk;
                    if "error" in c {
                        stream_error = str(c["error"]);
                        break;
                    }
                    piece: any = c.get("content");
                    if piece {
                        text = text + str(piece);
                        on_event("chunk", {"content": str(piece)});
                    }
                    if "tool_calls" in c { tool_calls = c["tool_calls"]; }
                }
            } except Exception as e {
                stream_error = str(e);
            }
            if not stream_error { break; }
            if retries < max_retries and _is_transient_error(stream_error) {
                retries += 1;
                on_event("retry", {
                    "attempt": retries,
                    "max_retries": max_retries,
                    "message": stream_error,
                });
                time.sleep(0.1 * retries);
                continue;
            }
            on_event("error", {"message": stream_error});
            return text;
        }
        if not tool_calls {
            messages.append({"role": "assistant", "content": text});
            return text;
        }
        messages.append({
            "role": "assistant",
            "content": text,
            "tool_calls": tool_calls,
        });
        for call in tool_calls {
            cl: any = call;
            fn: any = cl.get("function", {});
            name = str(fn.get("name", ""));
            raw: any = fn.get("arguments") or "{}";
            try {
                args = json.loads(raw);
            } except ValueError {
                args = {};
            }
            on_event("tool_call", {"tool": name, "args": args});
            if reg is not None {
                result = invoke(reg, name, args, bridge);
            } else {
                spec = _find_spec(specs, name);
                if spec is None or spec.handler is None {
                    result = f"ERROR: unknown tool {name}";
                } else {
                    try {
                        result = spec.handler(**args);
                    } except Exception as e {
                        result = f"ERROR: {e}";
                    }
                }
            }
            safe_result = _cap_tool_result(result);
            on_event("tool_result", {"tool": name, "result": safe_result});
            messages.append({
                "role": "tool",
                "tool_call_id": str(cl.get("id", "")),
                "content": safe_result,
            });
        }
    }
    on_event("loop_limit", {"max_iters": max_iters, "iterations": max_iters});
    return "";
}


# ================================ tests =====================================

obj RetryTransport(Transport) {
    has calls: int = 0;

    override def stream(messages: list, tool_defs: list) -> Generator[dict, None, None] {
        self.calls += 1;
        if self.calls == 1 {
            yield {"error": "HTTP 503: temporarily unavailable"};
        } else {
            yield {"content": "recovered"};
        }
    }
}


obj ScriptedTransport(Transport) {
    has tool_call_id: str = "call_1",
        tool_name: str = "echo",
        tool_args: str = "{\"text\": \"hi\"}",
        final_text: str = "done";

    override def stream(messages: list, tool_defs: list) -> Generator[dict, None, None] {
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
    assert kinds == ["chunk", "tool_call", "tool_result", "chunk"];
    tc = _events[1][1];
    assert tc["tool"] == "echo" and tc["args"] == {"text": "hi"};
    tr = _events[2][1];
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


test "unknown tool yields error result without crashing" {
    messages = [{"role": "user", "content": "go"}];
    spec = ScriptedTransport();
    spec.tool_name = "missing";
    _events.clear();
    answer = react_loop(messages, [], spec, _noop_event);
    assert "unknown tool" in _events[2][1]["result"];
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
    assert _events[2][1]["result"] == "JS:hi";
    dispose_bridge(bridge);
}
