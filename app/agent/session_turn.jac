"""Agent turn execution, rendering, hooks, and auto-compaction."""

import sys;
import os;
import time;

import from .session_state { history, show_stats, model, thinking_level, mode, plugins, _t0, _n_tools }
import from .session_config { set_model, set_thinking_level, _apply_pending_model_requests }
import from .llm {
    react_loop,
    make_transport,
    make_ext_transport,
    TurnCancel,
}
import from .compaction {
    load_project_config,
    resolve_auto_compact_config,
    compute_context_usage,
    should_auto_compact,
    build_mechanical_summary,
    summarize_for_compaction,
}
import from .system { SYSTEM_PROMPT }
import from .modes { system_prompt_for_mode }
import from .plugin_bridge {
    PluginBridge,
    input_gate,
    agent_start_gate,
    fire_hook,
    drain_extension_traffic,
    transform_markdown,
    render_extension_block,
}
import from .tools { default_registry }
import from .sessions { save_session, new_session_id, is_valid_session_id }
import from .session_lifecycle { session_boot, wait_extensions_ready }


def render_event(kind: str, data: dict[str, any]) {
    out: any = sys.stdout;
    if kind == "chunk" {
        out.write(str(data.get("content", "")));
        out.flush();
    } elif kind == "tool_call" {
        out.write("\n");
        args: any = data.get("args", {});
        parts: list[str] = [];
        for pair in args.items() {
            parts.append(str(pair[0]) + "=" + str(pair[1])[:40]);
        }
        out.write(f"  * {data.get('tool')}({(', '.join(parts))[:120]})\n");
        out.flush();
        _n_tools += 1;
    } elif kind == "tool_result" {
        preview = str(data.get("result", ""))[:80].replace("\n", " ");
        out.write(f"    -> {preview}\n");
        out.flush();
    } elif kind == "error" {
        out.write(f"\n[error] {data.get('message')}\n");
        out.flush();
    } elif kind == "extensions" {
        out.write(f"\n[{data.get('label', '')}]\n");
        out.flush();
    }
}




def relay_tool_hooks(bridge: PluginBridge | None, inner: any) -> any {
    if bridge is None {
        return inner;
    }
    def relayed(kind: str, data: dict[str, any]) {
        if kind == "tool_call" {
            fire_hook(bridge, "tool_execution_start", {
                "tool": str(data.get("tool", "")),
                "args": data.get("args", {}),
            });
        } elif kind == "tool_result" {
            fire_hook(bridge, "tool_execution_end", {
                "tool": str(data.get("tool", "")),
                "result": str(data.get("result", ""))[:2000],
            });
        }
        inner(kind, data);
    }
    return relayed;
}


"""Best-effort application of extension traffic pushed during a turn.

sendMessage/sendUserMessage payloads join LLM context (history); entries
and ui_events are transcript-only and surface as `entry` events. Never
raises — extension traffic must not break the turn.
"""
def _apply_extension_traffic(bridge: PluginBridge | None, on_event: any) {
    if bridge is None or on_event is None {
        return;
    }
    try {
        traffic: dict[str, any] = drain_extension_traffic(bridge);
        msgs: list[dict[str, any]] = traffic["messages"];
        for m in msgs {
            history.append({"role": str(m.get("role", "user")), "content": str(m.get("content", ""))});
        }
        raw_entries: list[dict[str, any]] = traffic["entries"];
        for e in raw_entries {
            ent: dict[str, any] = dict(e);
            # P11: an entry renderer matching this type upgrades the entry
            # with native content lines (app/ui paints them via
            # set_node_content); unmatched entries pass through untouched.
            try {
                r: dict[str, any] = render_extension_block(
                    bridge as PluginBridge, "entry", str(ent.get("type", "")), ent.get("data")
                );
                if r.get("ok") and r.get("lines") {
                    ent["lines"] = r["lines"];
                }
            } except Exception {
            }
            on_event("entry", ent);
        }
    } except Exception {
    }
}


"""Apply extension-issued pi.setModel / pi.setThinkingLevel requests drained
from the bridge. Goes through set_model/set_thinking_level so model_select /
thinking_level_select reach all listeners exactly once per change. Never
raises — a broken extension must not break the turn."""
def _apply_pending_model_requests() {
    b = plugins.bridge;
    if b is None {
        return;
    }
    raw_req: any = drain_model_requests(b as PluginBridge);
    req: dict[str, any] = raw_req as dict[str, any];
    m = str(req.get("model", ""));
    lv = str(req.get("thinking_level", ""));
    if m and m != model {
        set_model(m);
    }
    if lv and lv != thinking_level {
        set_thinking_level(lv);
    }
}


"""Best-effort auto-compaction of session history when the context threshold
is crossed (checked after the user message lands — matches src ordering).

Fires Pi's session_before_compact / session_after_compact hooks; a blocking
verdict ({block: true}) from any before-listener skips compaction this turn.
Never raises — compaction failure must not break the turn."""
def _maybe_auto_compact(bridge: PluginBridge | None) {
    try {
        cwd = plugins.cwd if plugins.cwd else os.getcwd();
        raw_cfg = load_project_config(cwd);
        cfg = resolve_auto_compact_config(
            raw_cfg, str(raw_cfg.get("compactStrategy", ""))
        );
        ctx_override: any = None;
        env_max: str = os.environ.get("JACKAL_CONTEXT_MAX", "");
        if env_max.isdigit() {
            ctx_override = int(env_max);
        }
        usage = compute_context_usage(history, ctx_override);
        if not should_auto_compact(usage, cfg) {
            return;
        }
        keep_tail: any = cfg.get("keepTail", 12);
        kt = int(keep_tail);
        if len(history) <= kt {
            return;
        }
        blocked = False;
        if bridge is not None {
            results = fire_hook(bridge as PluginBridge, "session_before_compact", {
                "messages_count": len(history),
                "percent": usage.get("percent"),
            });
            for r in results {
                v: any = r.get("verdict") if isinstance(r, dict) else None;
                if isinstance(v, dict) and v.get("block") {
                    blocked = True;
                    break;
                }
            }
        }
        if blocked {
            return;
        }
        count_before = len(history);
        dropped = history[:count_before - kt];
        kept = history[count_before - kt:];
        summary_text = build_mechanical_summary(dropped);
        strategy = "mechanical";
        if str(cfg.get("strategy", "mechanical")) == "llm" {
            llm_text = summarize_for_compaction(dropped, model, thinking_level);
            if llm_text is not None {
                summary_text = llm_text;
                strategy = "llm";
            }
        }
        compacted: list[dict[str, any]] = [{"role": "user", "content": summary_text}];
        for m in kept {
            compacted.append(m);
        }
        # Clear + refill (glob reassignment is a trap per SessionPlugins note).
        history.clear();
        for m in compacted {
            history.append(m);
        }
        if bridge is not None {
            fire_hook(bridge as PluginBridge, "session_after_compact", {
                "before": count_before,
                "after": len(history),
                "strategy": strategy,
            });
        }
    } except Exception {
    }
}


"""Seed or refresh the session system prompt for the active dev mode."""
def _ensure_mode_system_prompt {
    desired: str = system_prompt_for_mode(SYSTEM_PROMPT, mode);
    if not history {
        history.append({"role": "system", "content": desired});
        return;
    }
    for i in range(len(history)) {
        if str(history[i].get("role", "")) != "system" {
            continue;
        }
        current: str = str(history[i].get("content", ""));
        if (
            current == SYSTEM_PROMPT
            or "## Plan mode (active)" in current
            or "## Ask mode (active)" in current
        ) {
            history[i]["content"] = desired;
        }
        return;
    }
}


def run_turn(
    message: str,
    on_event: any = render_event,
    approve: any = None,
) -> str {
    # Auto-boot with no decls if never booted (native-only path).
    if plugins.reg is None {
        session_boot(plugins.session_id, plugins.cwd if plugins.cwd else os.getcwd(), []);
    }
    st = wait_extensions_ready();
    # Extensions may have called pi.setModel/setThinkingLevel during load.
    _apply_pending_model_requests();
    if on_event is not None and st.total > 0 {
        on_event(
            "extensions",
            {
                "label": st.label,
                "phase": st.phase,
                "loaded": st.loaded,
                "total": st.total,
                "detail": st.detail,
                "t_interactive_s": st.t_interactive_s,
                "t_ext_ready_s": st.t_ext_ready_s,
                "compat_tier": st.compat_tier,
            },
        );
    }
    bridge = plugins.bridge;
    # Pi event order: input -> before_agent_start -> turn/agent start.
    # `input` verdicts: handled skips the agent entirely (extension already
    # gave feedback via ctx.ui) and leaves zero trace — evaluated BEFORE the
    # system-prompt seed so a handled first turn does not grow history.
    if bridge is not None {
        try {
            igate = input_gate(bridge as PluginBridge, message);
        } except Exception {
            igate = {"action": "continue", "text": message};
        }
        if igate.get("action") == "handled" {
            _apply_extension_traffic(bridge as PluginBridge, on_event);
            return "";
        }
        if igate.get("action") == "transform" {
            message = str(igate.get("text", message));
        }
    }
    _ensure_mode_system_prompt();
    history.append({"role": "user", "content": message});
    # Auto-compact seam: threshold check after the user message lands.
    _maybe_auto_compact(bridge);
    # P10: extension-declared models route through the provider seam;
    # anything else uses the native provider table.
    transport: any = None;
    if model.startswith("ext/") {
        try {
            transport = make_ext_transport(bridge as PluginBridge, model, thinking=thinking_level);
        } except Exception {
            transport = None;
        }
        if transport is None {
            if on_event is not None {
                on_event("error", {"message": f"unknown extension model {model}"});
            }
            return "";
        }
    }
    if transport is None {
        transport = make_transport(model, thinking_level, hook_bridge=bridge);
    }
    _t0 = time.time();
    _n_tools = 0;
    # T2-partial lifecycle hooks — best-effort, never fatal.
    injected_system = "";
    sys_idx = -1;
    saved_sys = "";
    if bridge is not None {
        b = bridge as PluginBridge;
        # before_agent_start verdicts: systemPrompt replaces the system prompt
        # for THIS turn (restored after), message joins session history.
        try {
            agate = agent_start_gate(b, message);
        } except Exception {
            agate = {"message": "", "systemPrompt": ""};
        }
        injected_system = str(agate.get("systemPrompt", ""));
        if injected_system {
            for i in range(len(history)) {
                if str(history[i].get("role", "")) == "system" {
                    sys_idx = i;
                    saved_sys = str(history[i].get("content", ""));
                    history[i]["content"] = injected_system;
                    break;
                }
            }
        }
        inj_msg = str(agate.get("message", ""));
        if inj_msg {
            history.append({"role": "user", "content": inj_msg});
        }
        fire_hook(b, "turn_start", {"message": message});
        fire_hook(b, "agent_start", {"message": message});
    }
    answer = "";
    # Cooperative abort handle for this turn (/abort flips it from the UI).
    turn_cancel = TurnCancel();
    plugins.active_cancel = turn_cancel;
    try {
        reg = plugins.reg if plugins.reg is not None else default_registry();
        answer = react_loop(
            history, [], transport, relay_tool_hooks(bridge, on_event),
            reg=reg, bridge=bridge, cancel=turn_cancel, approve=approve,
        );
    } finally {
        plugins.active_cancel = None;
        if sys_idx >= 0 {
            # Per-turn system prompt swap is undone — Pi semantics: the
            # replacement lasts for this turn's LLM calls only.
            try {
                history[sys_idx]["content"] = saved_sys;
            } except Exception {
            }
        }
        if on_event is render_event {
            sys.stdout.write("\n");
            if show_stats {
                sys.stdout.write(
                    f"  [{time.time() - _t0:.1f}s - {_n_tools} tools]\n"
                );
            }
            sys.stdout.flush();
        } else {
            on_event("turn_end", {"secs": time.time() - _t0, "tools": _n_tools});
        }
        if bridge is not None {
            b2 = bridge as PluginBridge;
            fire_hook(b2, "turn_end", {
                "secs": time.time() - _t0,
                "tools": _n_tools,
                "answer": answer,
            });
            fire_hook(b2, "agent_end", {"answer": answer});
            fire_hook(b2, "agent_settled", {});
            _apply_extension_traffic(b2, on_event);
        }
        # Best-effort transcript persistence after every turn. The boot-time
        # id may be a placeholder ("session") — mint a real one on first save.
        try {
            if not is_valid_session_id(plugins.session_id) {
                plugins.session_id = new_session_id();
            }
            save_session(
                plugins.cwd if plugins.cwd else os.getcwd(),
                history,
                session_id=plugins.session_id,
            );
        } except Exception {
        }
    }
    # T2b: display-only markdown transformer chain over the complete answer,
    # surfaced as a `message` event for JSON/UI clients (term mode ignores it
    # — the raw stream is already printed). Never mutates session history.
    if answer and on_event is not None {
        xres = transform_markdown(bridge, answer);
        shown = str(xres.get("markdown", answer)) if xres.get("ok") else answer;
        on_event("message", {"role": "assistant", "content": shown});
        # P11: extension message renderer produces native content lines for
        # the finalized assistant message (surfaced as an entry event so
        # line-based and native-screen clients share one protocol).
        if bridge is not None {
            try {
                mr: dict[str, any] = render_extension_block(
                    bridge as PluginBridge,
                    "message",
                    "assistant",
                    {"role": "assistant", "content": shown},
                );
                if mr.get("ok") and mr.get("lines") {
                    on_event("entry", {
                        "type": "extension_render",
                        "render_type": "assistant",
                        "lines": mr["lines"],
                    });
                }
            } except Exception {
            }
        }
    }
    return answer;
}


