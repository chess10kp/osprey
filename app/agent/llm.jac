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
import from .plugin_bridge {
    PluginBridge,
    context_gate,
    prepare_provider_request,
    resolve_ext_model,
    tool_call_gate,
    tool_result_gate,
}




"""Cooperative turn-abort flag. Session owns one per active turn; the UI
thread flips `cancelled` and the ReAct loop checks it between stream chunks
and before each tool call. Plain fields — safe to set from another thread."""
obj TurnCancel {
    has turn_id: str = "",
        cancelled: bool = False,
        reason: str = "user";
}


obj Transport {
    has base_url: str = "https://api.openai.com/v1",
        api_key: str = "",
        model: str = "",
        thinking: str = "";

    def _build_body(messages: list, tool_defs: list) -> dict {
        # Single source of truth for the request body so tests can assert its
        # exact shape without network I/O. With thinking == "" the returned
        # dict is byte-identical to the pre-thinking-level body (no extra keys).
        body = {
            "model": self.model,
            "messages": messages,
            "stream": True,
        };
        if tool_defs { body["tools"] = tool_defs; }
        # Reasoning effort: these bodies are OpenAI/OpenRouter chat-completion
        # style, and OpenRouter's documented form is top-level
        # `reasoning: {"effort": ...}` (OpenAI-compatible too via mapping).
        # Omitted entirely when no level was requested.
        if self.thinking { body["reasoning"] = {"effort": self.thinking}; }
        return body;
    }

    def stream(messages: list, tool_defs: list) -> Generator[dict, None, None] {
        import httpx;
        body = self._build_body(messages, tool_defs);
        headers = {};
        if self.api_key { headers["Authorization"] = "Bearer " + self.api_key; }
        url = self.base_url.rstrip("/") + "/chat/completions";
        yield from self._open_stream(url, headers, body);
    }

    """POST `body` to `url` and yield normalized chunks (shared by native
    and P10 provider transports)."""
    def _open_stream(url: str, headers: dict, body: dict) -> Generator[dict, None, None] {
        import httpx;
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
whole model edge is one swappable module.

`model` is always explicit (callers may override the session default global
per turn); `thinking` optionally carries a reasoning level
("off"|"minimal"|"low"|"medium"|"high", "" = omit from request body).
"""
def make_transport(model: str = "", thinking: str = "") -> Transport {
    if model.startswith("openrouter/") {
        return Transport(
            base_url="https://openrouter.ai/api/v1",
            api_key=os.environ.get("OPENROUTER_API_KEY", ""),
            model=model[len("openrouter/"):],
            thinking=thinking,
        );
    }
    if model.startswith("deepseek/") {
        return Transport(
            base_url="https://api.deepseek.com/v1",
            api_key=os.environ.get("DEEPSEEK_API_KEY", ""),
            model=model[len("deepseek/"):],
            thinking=thinking,
        );
    }
    return Transport(
        base_url=os.environ.get("OPENAI_COMPAT_BASE", "https://api.openai.com/v1"),
        api_key=os.environ.get("OPENAI_API_KEY", ""),
        model=model,
        thinking=thinking,
    );
}


"""P10 provider transport: serves `ext/<extension>/<model>` model ids.

Resolves the owning extension's provider via bridge state, fires Pi's
`before_provider_request` hook before each POST (body/url/headers mutation —
full request control, trusted in-process code), then streams identically to
the native transport."""
obj ProviderTransport (Transport) {
    has ext_bridge: any = None,
        ext_cfg: dict = {};

    override def stream(messages: list, tool_defs: list) -> Generator[dict, None, None] {
        body = self._build_body(messages, tool_defs);
        headers = {};
        if self.api_key { headers["Authorization"] = "Bearer " + self.api_key; }
        url = self.base_url.rstrip("/") + "/chat/completions";
        if self.ext_bridge is not None {
            try {
                prepped = prepare_provider_request(
                    self.ext_bridge as PluginBridge,
                    self.model,
                    url,
                    headers,
                    body,
                );
                url = str(prepped.get("url", url));
                h2: any = prepped.get("headers");
                if isinstance(h2, dict) { headers = h2; }
                b2: any = prepped.get("body");
                if isinstance(b2, dict) { body = b2; }
            } except Exception {
                # Hook failure never blocks the request.
            }
        }
        yield from self._open_stream(url, headers, body);
    }
}


"""Build a transport for an extension-declared model id.

Returns None when the id is not in the ext/ namespace or no extension
declared it — callers fall back to native routing."""
def make_ext_transport(bridge: PluginBridge | None, model_id: str, thinking: str = "") -> ProviderTransport | None {
    cfg = resolve_ext_model(bridge, model_id);
    if cfg is None {
        return None;
    }
    t = ProviderTransport(
        base_url=str(cfg.get("base_url") or "https://api.openai.com/v1"),
        model=str(cfg.get("model", "")),
        thinking=thinking,
    );
    t.ext_bridge = bridge;
    t.ext_cfg = cfg;
    return t;
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
  cancelled  {"phase", "text"}   - cooperative abort via TurnCancel
  approval_request  {"tool", "args"}
  approval_decision {"tool", "approved"}
  error      {"message"}
When `cancel` fires mid-stream the partial text is returned but NOT appended
to history; when it fires before a tool runs, remaining calls get
cancelled-error tool results so the message protocol stays valid.
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
    cancel: TurnCancel | None = None,
    approve: any = None,
) -> str {
    def _is_cancelled() -> bool {
        return cancel is not None and cancel.cancelled;
    }

    """Gate a tool call through the optional approver. True allows; any other
    return (str reason) becomes the tool's error result."""
    def _approved(name: str, args: dict) -> any {
        if approve is None {
            return True;
        }
        try {
            return approve(name, args);
        } except Exception as e {
            return "approval gate failed: " + str(e);
        }
    }
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
            # Pi `context` hook (batch-2): handlers may edit a copy of the
            # messages per LLM call; edits apply to this call only — the
            # caller's history is never mutated.
            call_messages: list = messages;
            if bridge is not None {
                try {
                    call_messages = context_gate(bridge as PluginBridge, messages);
                } except Exception {
                    call_messages = messages;
                }
            }
            gen: any = transport.stream(call_messages, defs);
            aborted = False;
            try {
                for chunk_obj in gen {
                    if _is_cancelled() { aborted = True; break; }
                    c: any = chunk_obj;
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
            } finally {
                # Guard: custom Transport.stream impls may return a plain
                # iterator with no .close().
                try {
                    gen.close();
                } except AttributeError {
                }
            }
            if aborted {
                on_event("cancelled", {"phase": "streaming", "text": text});
                return text;
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
            if _is_cancelled() {
                # Keep the message protocol valid: every pending tool_call id
                # gets a terminal tool result.
                messages.append({
                    "role": "tool",
                    "tool_call_id": str(cl.get("id", "")),
                    "content": "ERROR: cancelled by user",
                });
                continue;
            }
            try {
                args = json.loads(raw);
            } except ValueError {
                args = {};
            }
            # Ask before executing; the approver may block (UI modal) or
            # deny outright. A cancel while waiting counts as denial.
            on_event("approval_request", {"tool": name, "args": args});
            verdict: any = _approved(name, args if isinstance(args, dict) else {});
            if verdict is not True or _is_cancelled() {
                result = "ERROR: cancelled by user" if _is_cancelled() else f"ERROR: {verdict}";
                on_event("approval_decision", {"tool": name, "approved": False});
                safe_result = _cap_tool_result(result);
                on_event("tool_result", {"tool": name, "result": safe_result});
                messages.append({
                    "role": "tool",
                    "tool_call_id": str(cl.get("id", "")),
                    "content": safe_result,
                });
                continue;
            }
            on_event("approval_decision", {"tool": name, "approved": True});
            on_event("tool_call", {"tool": name, "args": args});
            # Pi `tool_call` hook: handlers may mutate input in place and/or
            # return {block, reason?, terminate?}. First block wins.
            gate: dict = {"blocked": False, "reason": "", "terminate": False};
            if bridge is not None {
                try {
                    g = tool_call_gate(bridge as PluginBridge, name, args);
                    gated_args: any = g.get("args");
                    if isinstance(gated_args, dict) {
                        args = gated_args;
                    }
                    gate = {
                        "blocked": bool(g.get("blocked", False)),
                        "reason": str(g.get("reason", "")),
                        "terminate": bool(g.get("terminate", False)),
                    };
                } except Exception {
                    gate = {"blocked": False, "reason": "", "terminate": False};
                }
            }
            if gate["blocked"] {
                reason = gate["reason"];
                if reason {
                    result = f"ERROR: blocked by extension: {reason}";
                } else {
                    result = "ERROR: blocked by extension";
                }
            } elif reg is not None {
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
            # Pi `tool_result` hook: middleware-chained {content, isError}
            # patches rewrite what the LLM sees (display stream already got
            # the raw result above).
            if bridge is not None and not gate["blocked"] {
                try {
                    rg = tool_result_gate(bridge as PluginBridge, name, args, safe_result);
                    safe_result = str(rg.get("result", safe_result));
                } except Exception {
                }
            }
            on_event("tool_result", {"tool": name, "result": safe_result});
            messages.append({
                "role": "tool",
                "tool_call_id": str(cl.get("id", "")),
                "content": safe_result,
            });
            if gate["blocked"] and gate["terminate"] {
                # Pi: the agent stops early when a finalized result terminates.
                # Simplification vs parallel mode: calls run sequentially here,
                # so we stop at the first terminating block.
                on_event("error", {
                    "message": f"terminated by extension: {gate['reason']}",
                });
                return "";
            }
        }
        if _is_cancelled() {
            on_event("cancelled", {"phase": "tool", "text": text});
            return text;
        }
    }
    on_event("loop_limit", {"max_iters": max_iters, "iterations": max_iters});
    return "";
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
