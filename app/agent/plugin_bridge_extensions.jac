"""Plugin bridge extension loading and command/tool RPC."""

import os;

import from .protocol { Envelope, make_envelope, is_plugin_kind }
import from .registry { ToolRegistry, register_js, unregister_extension }
import from .fake_host { FakeUi, ensure_host, touch_bridge }
import from .plugin_bridge_support { _path_abspath }
import from .plugin_bridge_core {
    PluginBridge,
    _alloc_corr,
    _node_alive,
    _emit_host_status,
}
import from .plugin_bridge_host { ensure_node_host, maybe_restart_host, host_status }
import from .plugin_bridge_io {
    _write_node,
    _prepare_corr,
    _read_node_until,
}
import from .plugin_bridge_traffic { _absorb_payload, _absorb_pending_fake }

def load_extension(
    bridge: PluginBridge,
    reg: ToolRegistry,
    extension_id: str,
    tool_defs: list[dict[str, any]],
    handlers: dict[str, any],
) -> list[str] {
    if bridge.host_kind == "node" {
        raise RuntimeError("use load_extension_path for the Node host");
    }
    ensure_host(bridge);
    h = bridge.host;
    if h is None or not h.alive {
        raise RuntimeError("plugin host unavailable");
    }
    corr = _alloc_corr(bridge);
    names: list[str] = [];
    schemas: list[dict[str, any]] = [];
    for td in tool_defs {
        t: any = td;
        name = str(t.get("name", ""));
        if not name {
            continue;
        }
        names.append(name);
        raw_params: any = t.get("parameters", {});
        params: dict[str, any] = {};
        if isinstance(raw_params, dict) {
            params = raw_params;
        }
        schemas.append({
            "name": name,
            "description": str(t.get("description", "")),
            "parameters": params,
        });
        if name in handlers {
            h.handlers[name] = handlers[name];
        }
        register_js(
            reg,
            name=name,
            description=str(t.get("description", "")),
            parameters=params,
            extension_id=extension_id,
        );
    }
    h.extension_tools[extension_id] = names;
    # P10 fake parity: no activate-time hook exists on the fake host;
    # tests declare providers via register_fake_provider.
    bridge.inbox.append(
        make_envelope(
            kind="ext_loaded",
            session_id=bridge.session_id,
            correlation_id=corr,
            payload={"id": extension_id, "tools": schemas},
        )
    );
    touch_bridge(bridge);
    return names;
}


"""Return (ok, missing) for required capabilities vs host_caps (P4)."""
def caps_satisfied(bridge: PluginBridge, requires: list[str]) -> list[any] {
    missing: list[str] = [];
    for r in requires {
        need = str(r);
        if need and need not in bridge.host_caps {
            missing.append(need);
        }
    }
    return [len(missing) == 0, missing];
}


"""Composite capability gate (P12 slice 5): interactive_ui means the Node
host can round-trip AND this frontend installed a UI adapter. Line/JSON
frontends fail loud at ext_load instead of at first ui.select call."""
def ui_cap_satisfied(bridge: PluginBridge, requires: list[str], has_ui: bool) -> bool {
    if "interactive_ui" not in [str(x) for x in requires] {
        return True;
    }
    return has_ui;
}


"""Load a real JS module into the Node host and register its tools.

`requires` lists capability names the extension needs (e.g. commands). Missing
caps fail loud — never silent success with dead stubs (P4).
"""
def load_extension_path(
    bridge: PluginBridge,
    reg: ToolRegistry,
    extension_id: str,
    path: str,
    timeout: float = 5.0,
    requires: list[str] = [],
    has_ui: bool = False,
) -> list[str] {
    ensure_node_host(bridge);
    cap_check = caps_satisfied(bridge, requires);
    ok_caps: bool = bool(cap_check[0]);
    missing: list[str] = [];
    if len(cap_check) > 1 {
        raw_m: any = cap_check[1];
        if isinstance(raw_m, list) {
            missing = [str(x) for x in raw_m];
        }
    }
    if not ok_caps {
        detail = f"unsupported requirements for {extension_id}: {', '.join(missing)}";
        _emit_host_status(bridge, "degraded", detail);
        raise RuntimeError(detail);
    }
    if not ui_cap_satisfied(bridge, requires, has_ui) {
        detail = (
            f"requires interactive_ui but this frontend has no UI adapter "
            f"(line/JSON mode); extension {extension_id} refused"
        );
        _emit_host_status(bridge, "degraded", detail);
        raise RuntimeError(detail);
    }
    abs_path = _path_abspath(path);
    if not os.path.isfile(abs_path) {
        raise FileNotFoundError(f"extension module not found: {abs_path}");
    }
    # Builtin catalog rides ext_load so pi.getAllTools() sees the full
    # surface (native-origin tools only; js tools come from other exts).
    builtins: list[dict[str, any]] = [];
    for tool_entry in reg.tools.values() {
        if tool_entry.origin == "native" {
            builtins.append({
                "name": tool_entry.name,
                "description": tool_entry.description,
                "parameters": tool_entry.parameters,
            });
        }
    }
    corr = _alloc_corr(bridge);
    _prepare_corr(bridge, corr, expect_kind="ext_loaded");
    req = make_envelope(
        kind="ext_load",
        session_id=bridge.session_id,
        correlation_id=corr,
        payload={
            "id": extension_id,
            "path": abs_path,
            "requires": [str(x) for x in requires],
            "has_ui": bool(has_ui),
            "builtins": builtins,
        },
    );
    _write_node(bridge, req);
    reply = _read_node_until(bridge, "ext_loaded", correlation_id=corr, timeout=timeout);
    _absorb_payload(bridge, dict(reply.payload));
    err = reply.payload.get("error", "");
    if err {
        raise RuntimeError(f"ext_load failed: {err}");
    }
    unsup: any = reply.payload.get("unsupported", []);
    if isinstance(unsup, list) and unsup {
        detail = f"host rejected requirements: {', '.join([str(x) for x in unsup])}";
        _emit_host_status(bridge, "degraded", detail);
        raise RuntimeError(detail);
    }
    tools = reply.payload.get("tools", []);
    names: list[str] = [];
    for td in tools {
        t: any = td;
        name = str(t.get("name", ""));
        if not name {
            continue;
        }
        names.append(name);
        raw_params: any = t.get("parameters", {});
        params: dict[str, any] = {};
        if isinstance(raw_params, dict) {
            params = raw_params;
        }
        register_js(
            reg,
            name=name,
            description=str(t.get("description", "")),
            parameters=params,
            extension_id=extension_id,
        );
    }
    # T2-partial: track registered commands so the session/UI can route them.
    cmds: list[any] = reply.payload.get("commands", []);
    if isinstance(cmds, list) {
        for cd in cmds {
            c: any = cd;
            cname = str(c.get("name", ""));
            if cname {
                bridge.commands[cname] = {
                    "name": cname,
                    "description": str(c.get("description", "")),
                    "extension_id": extension_id,
                };
            }
        }
    }
    touch_bridge(bridge);
    return names;
}


def unload_extension(
    bridge: PluginBridge, reg: ToolRegistry, extension_id: str
) -> int {
    removed = unregister_extension(reg, extension_id);
    dead: list[str] = [];
    for n in list(bridge.commands.keys()) {
        if bridge.commands[n].get("extension_id") == extension_id {
            dead.append(n);
        }
    }
    for n in dead {
        bridge.commands.pop(n, None);
    }
    bridge.md_transformers = [
        t for t in bridge.md_transformers
        if t.get("extension_id") != extension_id
    ];
    # No tuple unpacking in comprehensions: the Jac parser rejects
    # `for n, c in ...`, so mirror the dead-command loop above.
    for pn in list(bridge.providers.keys()) {
        if bridge.providers[pn].get("extension_id") == extension_id {
            bridge.providers.pop(pn, None);
        }
    }
    for sk in list(bridge.shortcuts.keys()) {
        if bridge.shortcuts[sk].get("extension_id") == extension_id {
            bridge.shortcuts.pop(sk, None);
        }
    }
    for lid in list(bridge.labels.keys()) {
        if bridge.labels[lid].get("extension_id") == extension_id {
            bridge.labels.pop(lid, None);
        }
    }
    if bridge.host_kind == "node" and _node_alive(bridge) {
        req = make_envelope(
            kind="ext_unload",
            session_id=bridge.session_id,
            payload={"id": extension_id},
        );
        try {
            _write_node(bridge, req);
        } except Exception {
        }
        return removed;
    }
    ensure_host(bridge);
    h = bridge.host;
    if h is not None {
        names = h.extension_tools.pop(extension_id, []);
        for name in names {
            if name in h.handlers {
                del h.handlers[name];
            }
        }
        dead_cmds = [
            n for n in list(h.command_handlers.keys())
            if h.command_handlers[n].get("owner") == extension_id
        ];
        for n in dead_cmds {
            del h.command_handlers[n];
        }
        h.md_transformers = [
            t for t in h.md_transformers
            if t.get("extension_id") != extension_id
        ];
        # Jac parser rejects tuple unpacking in comprehensions.
        for pn in list(h.providers.keys()) {
            if h.providers[pn].get("owner") == extension_id {
                h.providers.pop(pn, None);
            }
        }
        for table in (h.message_renderers, h.entry_renderers) {
            for rn in list(table.keys()) {
                r: any = table[rn];
                if isinstance(r, dict) and r.get("owner") == extension_id {
                    table.pop(rn, None);
                }
            }
        }
    }
    return removed;
}


def invoke_shortcut(bridge: PluginBridge, key: str, timeout: float = 10.0) -> dict[str, any] {
    if bridge.host_kind == "node" {
        if not _node_alive(bridge) {
            phase = maybe_restart_host(bridge);
            if phase != "ready" or not _node_alive(bridge) {
                host_status(bridge);
                return {"ok": False, "error": "plugin host unavailable"};
            }
        }
        corr = _alloc_corr(bridge);
        _prepare_corr(bridge, corr, expect_kind="shortcut_result");
        req = make_envelope(
            kind="shortcut_invoke",
            session_id=bridge.session_id,
            correlation_id=corr,
            payload={"key": key},
        );
        try {
            _write_node(bridge, req);
            reply = _read_node_until(
                bridge, "shortcut_result", correlation_id=corr, timeout=timeout
            );
        } except Exception as e {
            return {"ok": False, "error": str(e)};
        }
        touch_bridge(bridge);
        # Absorb reply-attached extension traffic and model/thinking requests
        # issued inside shortcut handlers.
        _absorb_payload(bridge, dict(reply.payload));
        return dict(reply.payload);
    }
    # Fake host path.
    try {
        ensure_host(bridge);
    } except Exception as e {
        return {"ok": False, "error": str(e)};
    }
    h = bridge.host;
    if h is None or not h.alive {
        return {"ok": False, "error": "plugin host unavailable"};
    }
    shortcut_entry = h.shortcut_handlers.get(key);
    if shortcut_entry is None {
        return {"ok": False, "error": f"unknown shortcut {key}"};
    }
    notifications: list[str] = [];
    try {
        ui = FakeUi(notifications, []);
        result = shortcut_entry["handler"]({"ui": ui});
        res_payload: dict[str, any] = {
            "ok": True,
            "result": "" if result is None else str(result),
            "notifications": notifications,
        };
        if ui.ui_events {
            res_payload["ui_events"] = list(ui.ui_events);
        }
        _absorb_pending_fake(bridge, h);
        _absorb_payload(bridge, res_payload);
        return res_payload;
    } except Exception as e {
        err_payload: dict[str, any] = {
            "ok": False,
            "error": str(e),
            "notifications": notifications,
        };
        _absorb_pending_fake(bridge, h);
        return err_payload;
    }
}


def cancel_tool(bridge: PluginBridge, correlation_id: str) {
    if bridge.host_kind == "node" and _node_alive(bridge) {
        req = make_envelope(
            kind="tool_cancel",
            session_id=bridge.session_id,
            correlation_id=correlation_id,
            payload={},
        );
        try {
            _write_node(bridge, req);
        } except Exception {
        }
        return;
    }
    ensure_host(bridge);
    h = bridge.host;
    if h is not None {
        h.cancelled.add(correlation_id);
    }
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


# ======================= T2-partial: commands + hooks =======================

"""Invoke an extension command. Returns the cmd_result payload dict:
{ok, result?, error?, notifications?}. Raises TimeoutError on Node silence."""
def invoke_command(
    bridge: PluginBridge, name: str, args: str = "", timeout: float = 10.0
) -> dict[str, any] {
    if bridge.host_kind == "node" {
        if not _node_alive(bridge) {
            phase = maybe_restart_host(bridge);
            if phase != "ready" or not _node_alive(bridge) {
                host_status(bridge);
                return {"ok": False, "error": "plugin host unavailable"};
            }
        }
        corr = _alloc_corr(bridge);
        _prepare_corr(bridge, corr, expect_kind="cmd_result");
        req = make_envelope(
            kind="cmd_invoke",
            session_id=bridge.session_id,
            correlation_id=corr,
            payload={"name": name, "args": args},
        );
        try {
            _write_node(bridge, req);
            reply = _read_node_until(
                bridge, "cmd_result", correlation_id=corr, timeout=timeout
            );
        } except Exception as e {
            return {"ok": False, "error": str(e)};
        }
        touch_bridge(bridge);
        # Absorb reply-attached extension traffic and model/thinking requests
        # issued inside command handlers.
        _absorb_payload(bridge, dict(reply.payload));
        return dict(reply.payload);
    }
    # Fake host path.
    try {
        ensure_host(bridge);
    } except Exception as e {
        return {"ok": False, "error": str(e)};
    }
    h = bridge.host;
    if h is None or not h.alive {
        return {"ok": False, "error": "plugin host unavailable"};
    }
    handler_entry = h.command_handlers.get(name);
    if handler_entry is None {
        return {"ok": False, "error": f"unknown command {name}"};
    }
    notifications: list[str] = [];
    try {
        ui = FakeUi(notifications, []);
        result = handler_entry["handler"](args, {"ui": ui});
        res_payload: dict[str, any] = {
            "ok": True,
            "result": "" if result is None else str(result),
            "notifications": notifications,
        };
        if ui.ui_events {
            res_payload["ui_events"] = list(ui.ui_events);
        }
        _absorb_pending_fake(bridge, h);
        _absorb_payload(bridge, res_payload);
        return res_payload;
    } except Exception as e {
        err_payload: dict[str, any] = {
            "ok": False,
            "error": str(e),
            "notifications": notifications,
        };
        _absorb_pending_fake(bridge, h);
        return err_payload;
    }
}
