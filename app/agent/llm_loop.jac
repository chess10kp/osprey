"""ReAct loop and cooperative cancellation for the agent model layer."""

import json;
import time;
import from collections.abc { Generator }
import from .tool_spec { ToolSpec, MAX_TOOL_RESULT }
import from .llm_transport { Transport }
import from .registry { ToolRegistry, as_tool_specs, invoke }
import from .plugin_bridge {
    PluginBridge,
    context_gate,
    fire_hook,
    tool_call_gate,
    tool_result_gate,
}

obj TurnCancel {
    has turn_id: str = "",
        cancelled: bool = False,
        reason: str = "user";
}



def _tool_defs(specs: list[ToolSpec]) -> list[dict[str, any]] {
    defs: list[dict[str, any]] = [];
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
def _notify_message_end(bridge: any, message: dict[str, any]) {
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
    messages: list[dict[str, any]],
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
    def _approved(name: str, args: dict[str, any]) -> any {
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
        tool_calls: list[dict[str, any]] = [];
        retries = 0;
        while True {
            stream_error = "";
            text = "";
            tool_calls = [];
            # Pi `context` hook (batch-2): handlers may edit a copy of the
            # messages per LLM call; edits apply to this call only — the
            # caller's history is never mutated.
            call_messages: list[dict[str, any]] = messages;
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
            final_msg: dict[str, any] = {"role": "assistant", "content": text};
            messages.append(final_msg);
            _notify_message_end(bridge, final_msg);
            return text;
        }
        tc_msg: dict[str, any] = {
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
            gate: dict[str, any] = {"blocked": False, "reason": "", "terminate": False};
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
