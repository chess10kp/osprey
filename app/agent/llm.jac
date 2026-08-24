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
    fire_hook,
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

    # Pi `after_provider_response` parity (see docs/AFTER-PROVIDER-RESPONSE-NOTE.md):
    # informational-only {status, headers}, fired when response headers arrive,
    # before the body is consumed. hook_bridge is the PluginBridge whose Node
    # sidecar hosts extension hooks; None disables. hook_timeout bounds the
    # stdio round trip so a hung handler never stalls stream-open.
    has hook_bridge: any = None,
        hook_timeout: float = 2.0;

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

    """Fire the informational after_provider_response hook (Pi parity).
    Never raises and never blocks longer than hook_timeout — a failing or
    hung hook must not affect the stream."""
    def _notify_response(status: int, headers: dict) {
        if self.hook_bridge is None {
            return;
        }
        try {
            fire_hook(
                self.hook_bridge as PluginBridge,
                "after_provider_response",
                {"status": status, "headers": dict(headers)},
                timeout=self.hook_timeout,
            );
        } except Exception {
            # Informational: hook failures are silent by design.
        }
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
            # Fire strictly before the first line is read so handlers observe
            # "provider answered" ahead of any content event downstream.
            self._notify_response(r.status_code, dict(r.headers));
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


"""fx-style provider-first routing (see ~/notes/fx-model-routing.md).

One table owns every provider fact — endpoint, credential env var, catalog —
and both routing (`provider_for`) and credential validation
(`credential_error`) dispatch through it. Prefix matching is CASE-SENSITIVE
on purpose: it preserves the exact `startswith` semantics make_transport had
before the table existed ("OpenRouter/..." was never a routed id).

Route fields:
  description   human-facing provider blurb (/model UI)
  base_url      default chat-completions endpoint
  base_url_env  optional env var overriding base_url (openai_compat only)
  key_env       bearer-token env var; "" = provider needs no credential
  models        static catalog hints (informational)
"""
glob PROVIDER_ROUTES: dict = {
    "openrouter": {
        "description": "OpenRouter multi-provider gateway",
        "base_url": "https://openrouter.ai/api/v1",
        "base_url_env": "",
        "key_env": "OPENROUTER_API_KEY",
        "models": ["anthropic/claude-sonnet-5", "openai/gpt-5"],
    },
    "deepseek": {
        "description": "DeepSeek API",
        "base_url": "https://api.deepseek.com/v1",
        "base_url_env": "",
        "key_env": "DEEPSEEK_API_KEY",
        "models": ["deepseek-chat", "deepseek-reasoner"],
    },
    "openai_compat": {
        "description": "Any OpenAI-compatible chat-completions endpoint",
        "base_url": "https://api.openai.com/v1",
        "base_url_env": "OPENAI_COMPAT_BASE",
        "key_env": "OPENAI_API_KEY",
        "models": ["gpt-4o", "gpt-4o-mini"],
    },
    "mock": {
        "description": "Local mockllm (no network, no credential)",
        "base_url": "local://mockllm",
        "base_url_env": "",
        "key_env": "",
        "models": ["mock"],
    },
};


"""Map a model id to its provider id (pure function — reads nothing).

Dispatch:
  "openrouter/<model>"          -> "openrouter"
  "deepseek/<model>"            -> "deepseek"
  "mock" | "mockllm" | "mock/*" -> "mock"
  "ext/<extension>/<model>"     -> "ext" (resolved via plugin bridge)
  anything else                 -> "openai_compat"
"""
def provider_for(model: str) -> str {
    if model.startswith("openrouter/") { return "openrouter"; }
    if model.startswith("deepseek/") { return "deepseek"; }
    if model == "mock" or model == "mockllm" or model.startswith("mock/") {
        return "mock";
    }
    if model.startswith("ext/") { return "ext"; }
    return "openai_compat";
}


"""fx-style actionable credential check. Returns "" when the model is
usable; otherwise ONE sentence naming the exact fix. Reads only os.environ
and never raises.
"""
def credential_error(model: str) -> str {
    try {
        provider = provider_for(model);
        if provider == "ext" { return ""; }
        route: any = PROVIDER_ROUTES.get(provider);
        if route is None { return ""; }
        key_env = str(route.get("key_env", ""));
        if not key_env { return ""; }
        if os.environ.get(key_env, "") { return ""; }
        fix = f'set {key_env}';
        if provider == "openai_compat" {
            fix += " (or point OPENAI_COMPAT_BASE at your endpoint)";
        }
        return (
            f'model "{model}" routes via {provider} — {fix}'
            + " or pick another provider (/model for options)."
        );
    } except Exception {
        return "";
    }
}


"""Pick a transport from the model name. Provider table lives here so the
whole model edge is one swappable module.

`model` is always explicit (callers may override the session default global
per turn); `thinking` optionally carries a reasoning level
("off"|"minimal"|"low"|"medium"|"high", "" = omit from request body).

Historical wiring preserved verbatim: unresolved `ext/` ids still fall back
to the OpenAI-compatible endpoint (session resolves ext ids through
make_ext_transport FIRST; this is the native fallback path). `mock` ids get
the table's local:// marker instead of silently billing a real endpoint.
"""
def make_transport(model: str = "", thinking: str = "", hook_bridge: any = None) -> Transport {
    provider = provider_for(model);
    if provider == "ext" { provider = "openai_compat"; }
    route: dict = PROVIDER_ROUTES[provider];
    prefix = provider + "/";
    stripped = model;
    if model.startswith(prefix) { stripped = model[len(prefix):]; }
    key_env = str(route.get("key_env", ""));
    api_key = os.environ.get(key_env, "") if key_env else "";
    base_url_env = str(route.get("base_url_env", ""));
    base_url = os.environ.get(base_url_env, str(route["base_url"])) if base_url_env else str(route["base_url"]);
    return Transport(
        base_url=base_url,
        api_key=api_key,
        model=stripped,
        thinking=thinking,
        hook_bridge=hook_bridge,
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
    # Same informational hook surface as native transports (ProviderTransport
    # additionally fires before_provider_request in its own stream override).
    t.hook_bridge = bridge;
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


"""Best-effort Pi message_end relay for one finalized assistant message.
Never raises — hook transport failures must not break the turn."""
def _notify_message_end(bridge: any, message: dict) {
    if bridge is None {
        return;
    }
    try {
        fire_hook(bridge as PluginBridge, "message_end", {"message": message});
    } except Exception {
    }
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
            final_msg: dict = {"role": "assistant", "content": text};
            messages.append(final_msg);
            _notify_message_end(bridge, final_msg);
            return text;
        }
        tc_msg: dict = {
            "role": "assistant",
            "content": text,
            "tool_calls": tool_calls,
        };
        messages.append(tc_msg);
        _notify_message_end(bridge, tc_msg);
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
            # Abort during the gate dialog must not execute the tool.
            if _is_cancelled() {
                messages.append({
                    "role": "tool",
                    "tool_call_id": str(cl.get("id", "")),
                    "content": "ERROR: cancelled by user",
                });
                continue;
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
