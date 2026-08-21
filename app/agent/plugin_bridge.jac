"""In-process plugin bridge (D11/D13 spike steps 1–2).

Speaks the same Envelope types as agent.protocol. No Node yet: a FakePluginHost
handles ext_load / tool_invoke / tool_cancel synchronously so registry + kind
helpers can be proven without spawning a JS process.
"""

import from typing { Callable }

import from .protocol {
    Envelope,
    make_envelope,
    is_plugin_kind,
}
import from .registry {
    ToolRegistry,
    register_js,
    unregister_extension,
}


obj FakePluginHost {
    has handlers: dict[str, Callable] = {},
        extension_tools: dict[str, list[str]] = {},
        cancelled: set[str] = set(),
        node_version: str = "fake",
        alive: bool = True;
}


obj PluginBridge {
    has session_id: str = "",
        host: FakePluginHost | None = None,
        next_corr: int = 1,
        outbox: list[Envelope] = [],
        inbox: list[Envelope] = [];

    """Dispatch a js tool through the fake host (used by registry.invoke)."""
    def invoke_js_tool(name: str, args: dict) -> str {
        return invoke_tool(self, name, args);
    }
}


def create_bridge(session_id: str) -> PluginBridge {
    return PluginBridge(session_id=session_id);
}


def create_fake_host(node_version: str = "fake") -> FakePluginHost {
    return FakePluginHost(node_version=node_version);
}


"""Attach an in-process host (lazy ensure). Emits host_hello into inbox."""
def ensure_host(bridge: PluginBridge, host: FakePluginHost | None = None) -> str {
    if bridge.host is not None and bridge.host.alive {
        return "ready";
    }
    h = host if host is not None else create_fake_host();
    bridge.host = h;
    h.alive = True;
    bridge.inbox.append(
        make_envelope(
            kind="host_hello",
            session_id=bridge.session_id,
            payload={
                "protocol": 1,
                "node": h.node_version,
                "caps": ["tools"],
            },
        )
    );
    return "ready";
}


def dispose_bridge(bridge: PluginBridge) {
    if bridge.host is not None {
        bridge.host.alive = False;
        bridge.inbox.append(
            make_envelope(
                kind="host_goodbye",
                session_id=bridge.session_id,
                payload={"reason": "dispose"},
            )
        );
    }
    bridge.host = None;
    bridge.outbox.clear();
}


"""Install a stub extension into the fake host and registry.

`tool_defs` entries: {name, description, parameters}.
`handlers` maps tool name → callable.
"""
def load_extension(
    bridge: PluginBridge,
    reg: ToolRegistry,
    extension_id: str,
    tool_defs: list,
    handlers: dict[str, Callable],
) -> list[str] {
    ensure_host(bridge);
    h = bridge.host;
    if h is None or not h.alive {
        raise RuntimeError("plugin host unavailable");
    }
    corr = "corr-" + str(bridge.next_corr);
    bridge.next_corr += 1;
    bridge.outbox.append(
        make_envelope(
            kind="ext_load",
            session_id=bridge.session_id,
            correlation_id=corr,
            payload={"id": extension_id, "path": "in-process:" + extension_id},
        )
    );
    names: list[str] = [];
    schemas: list = [];
    for td in tool_defs {
        t: any = td;
        name = str(t.get("name", ""));
        if not name {
            continue;
        }
        names.append(name);
        schemas.append({
            "name": name,
            "description": str(t.get("description", "")),
            "parameters": t.get("parameters", {}),
        });
        if name in handlers {
            h.handlers[name] = handlers[name];
        }
        register_js(
            reg,
            name=name,
            description=str(t.get("description", "")),
            parameters=t.get("parameters", {}),
            extension_id=extension_id,
        );
    }
    h.extension_tools[extension_id] = names;
    bridge.inbox.append(
        make_envelope(
            kind="ext_loaded",
            session_id=bridge.session_id,
            correlation_id=corr,
            payload={"id": extension_id, "tools": schemas},
        )
    );
    # Consume the matching outbox load request (fake host "processed" it).
    if bridge.outbox {
        bridge.outbox.pop(0);
    }
    return names;
}


def unload_extension(
    bridge: PluginBridge, reg: ToolRegistry, extension_id: str
) -> int {
    ensure_host(bridge);
    h = bridge.host;
    removed = unregister_extension(reg, extension_id);
    if h is not None {
        names = h.extension_tools.pop(extension_id, []);
        for name in names {
            if name in h.handlers {
                del h.handlers[name];
            }
        }
    }
    bridge.outbox.append(
        make_envelope(
            kind="ext_unload",
            session_id=bridge.session_id,
            payload={"id": extension_id},
        )
    );
    if bridge.outbox {
        bridge.outbox.pop(0);
    }
    return removed;
}


"""Invoke a js tool via tool_invoke / tool_result envelopes on the fake host."""
def invoke_tool(bridge: PluginBridge, name: str, args: dict) -> str {
    ensure_host(bridge);
    h = bridge.host;
    if h is None or not h.alive {
        return "ERROR: plugin host unavailable";
    }
    corr = "corr-" + str(bridge.next_corr);
    bridge.next_corr += 1;
    bridge.outbox.append(
        make_envelope(
            kind="tool_invoke",
            session_id=bridge.session_id,
            tool_id=name,
            correlation_id=corr,
            payload={"name": name, "args": args},
        )
    );
    if corr in h.cancelled {
        bridge.outbox.pop(0);
        result_env = make_envelope(
            kind="tool_result",
            session_id=bridge.session_id,
            tool_id=name,
            correlation_id=corr,
            payload={"ok": False, "error": "cancelled"},
        );
        bridge.inbox.append(result_env);
        return "ERROR: cancelled";
    }
    if name not in h.handlers {
        bridge.outbox.pop(0);
        bridge.inbox.append(
            make_envelope(
                kind="tool_result",
                session_id=bridge.session_id,
                tool_id=name,
                correlation_id=corr,
                payload={"ok": False, "error": f"unknown tool {name}"},
            )
        );
        return f"ERROR: unknown js tool {name}";
    }
    try {
        result = str(h.handlers[name](**args));
        ok = True;
        err = "";
    } except Exception as e {
        result = "";
        ok = False;
        err = str(e);
    }
    if bridge.outbox {
        bridge.outbox.pop(0);
    }
    payload: dict[str, any] = {"ok": ok};
    if ok {
        payload["result"] = result;
    } else {
        payload["error"] = err if err else "invoke failed";
    }
    bridge.inbox.append(
        make_envelope(
            kind="tool_result",
            session_id=bridge.session_id,
            tool_id=name,
            correlation_id=corr,
            payload=payload,
        )
    );
    if ok {
        return result;
    }
    return f"ERROR: {payload['error']}";
}


def cancel_tool(bridge: PluginBridge, correlation_id: str) {
    ensure_host(bridge);
    h = bridge.host;
    if h is not None {
        h.cancelled.add(correlation_id);
    }
    bridge.outbox.append(
        make_envelope(
            kind="tool_cancel",
            session_id=bridge.session_id,
            correlation_id=correlation_id,
            payload={},
        )
    );
}


"""Drain inbox plugin envelopes; return kinds seen (tests / status)."""
def drain_inbox(bridge: PluginBridge) -> list[str] {
    kinds: list[str] = [];
    while bridge.inbox {
        env = bridge.inbox.pop(0);
        if is_plugin_kind(env.kind) {
            kinds.append(env.kind);
        }
    }
    return kinds;
}
