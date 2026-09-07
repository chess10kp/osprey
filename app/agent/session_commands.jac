"""Session history, extension command, and JSONL protocol helpers."""

import sys;
import json;

import from .session_state { history, plugins }
import from .session_config { _apply_pending_model_requests }
import from .plugin_bridge {
    PluginBridge,
    invoke_command,
    invoke_shortcut,
    list_shortcuts,
    list_labels,
}
import from .sessions { new_session_id }


def get_history() -> list[dict[str, any]] {
    return list(history);
}


"""Replace in-memory history with a loaded transcript (restore flow)."""
def restore_history(msgs: list[dict[str, any]]) {
    history.clear();
    for m in msgs {
        if isinstance(m, dict) {
            history.append(dict(m));
        }
    }
}


def set_current_session_id(sid: str) {
    plugins.session_id = sid if sid else new_session_id();
}


"""Request cooperative abort of the active turn (if any). Safe to call from
the UI thread while run_turn is streaming. Returns True when a live turn was
flagged; False when no turn is in flight or it was already cancelled."""
def cancel_active_turn() -> bool {
    c = plugins.active_cancel;
    if c is not None and not c.cancelled {
        c.cancelled = True;
        return True;
    }
    return False;
}


"""Extension commands visible to the shell/UI (name -> description meta).

The bridge owns the authoritative set; this re-syncs from it so commands
registered/unloaded after warm-up are reflected immediately.
"""
def list_commands() -> dict[str, any] {
    b = plugins.bridge;
    if b is not None {
        plugins.commands = dict((b as PluginBridge).commands);
    }
    return dict(plugins.commands);
}


"""Invoke an extension command through the plugin bridge.

Returns a display string: the command result plus any ctx.ui.notify lines the
handler emitted. Never raises — failures come back as ERROR strings.
"""
def run_command(name: str, args: str = "") -> str {
    bridge = plugins.bridge;
    if bridge is None {
        return f"ERROR: no plugin host running (command /{name} unavailable)";
    }
    res: dict[str, any] = invoke_command(bridge as PluginBridge, name, args);
    # A command handler may have called pi.setModel/setThinkingLevel.
    _apply_pending_model_requests();
    lines: list[str] = [];
    for note in res.get("notifications", []) or [] {
        lines.append(str(note));
    }
    if res.get("ok") {
        result_s = str(res.get("result", ""));
        if result_s {
            lines.append(result_s);
        }
    } else {
        lines.append("ERROR: " + str(res.get("error", "command failed")));
    }
    return "\n".join(lines);
}


"""Fire an extension keyboard shortcut by key (TUI keybinding path).

Returns a display string: handler notifications + result, or an ERROR line.
Never raises. Shortcut handlers may call pi.setModel/setThinkingLevel.
"""
def run_extension_shortcut(key: str) -> str {
    bridge = plugins.bridge;
    if bridge is None {
        return f"ERROR: no plugin host running (shortcut {key} unavailable)";
    }
    res: dict[str, any] = invoke_shortcut(bridge as PluginBridge, key);
    _apply_pending_model_requests();
    lines: list[str] = [];
    for note in res.get("notifications", []) or [] {
        lines.append(str(note));
    }
    if res.get("ok") {
        result_s = str(res.get("result", ""));
        if result_s {
            lines.append(result_s);
        }
    } else {
        lines.append("ERROR: " + str(res.get("error", "shortcut failed")));
    }
    return "\n".join(lines);
}


"""Shortcut bindings registered by loaded extensions (key -> meta with
extension_id + description). Listed for host UIs; the TUI input loop matches
keypresses against these and fires them via run_extension_shortcut."""
def list_extension_shortcuts() -> dict[str, any] {
    return list_shortcuts(plugins.bridge);
}


"""Labels set by loaded extensions via pi.setLabel (id -> meta)."""
def list_extension_labels() -> dict[str, any] {
    return list_labels(plugins.bridge);
}


"""JSONL event sink: one serialized event per line on stdout. This IS the
harness's UI protocol."""
def json_event(kind: str, data: dict[str, any]) {
    line = json.dumps({"type": kind, **data});
    out: any = sys.stdout;
    out.write(line + "\n");
    out.flush();
}
