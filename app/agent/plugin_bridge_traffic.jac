"""Plugin bridge traffic buffers and pending extension controls."""

import from .plugin_bridge_core { PluginBridge };
import from .fake_host { FakePluginHost };

def _absorb_payload(bridge: PluginBridge, payload: dict[str, any]) {
    msgs: any = payload.get("messages", []);
    if isinstance(msgs, list) {
        for m in msgs {
            if isinstance(m, dict) {
                bridge.traffic_messages.append({
                    "role": str(m.get("role", "user")),
                    "content": str(m.get("content", "")),
                });
            }
        }
    }
    ents: any = payload.get("entries", []);
    if isinstance(ents, list) {
        for e in ents {
            if isinstance(e, dict) {
                bridge.traffic_entries.append(dict(e));
            }
        }
    }
    uis: any = payload.get("ui_events", []);
    if isinstance(uis, list) {
        for u in uis {
            if isinstance(u, dict) {
                bridge.traffic_entries.append({
                    "type": "ui_event",
                    "method": str(u.get("method", "")),
                    "args": u.get("args", []),
                });
            }
        }
    }
    sn = payload.get("session_name", "");
    if sn {
        bridge.session_name = str(sn);
    }
    # P10: provider declarations ride ext_loaded payloads.
    provs: any = payload.get("providers", []);
    if isinstance(provs, list) {
        for p in provs {
            if isinstance(p, dict) and p.get("name") {
                cfg = dict(p);
                cfg["extension_id"] = str(payload.get("id", ""));
                bridge.providers[str(p.get("name"))] = cfg;
            }
        }
    }
    # Shortcut/label registrations ride ext_loaded payloads; the TUI input
    # loop binds shortcut keys and fires them via invoke_shortcut.
    scs: any = payload.get("shortcuts", []);
    if isinstance(scs, list) {
        for sc in scs {
            if isinstance(sc, dict) and sc.get("key") {
                meta = dict(sc);
                meta["extension_id"] = str(payload.get("id", ""));
                bridge.shortcuts[str(sc.get("key"))] = meta;
            }
        }
    }
    lbs: any = payload.get("labels", []);
    if isinstance(lbs, list) {
        for lb in lbs {
            if isinstance(lb, dict) and lb.get("id") {
                lmeta = dict(lb);
                lmeta["extension_id"] = str(payload.get("id", ""));
                bridge.labels[str(lb.get("id"))] = lmeta;
            }
        }
    }
    # Extension-issued pi.setModel / pi.setThinkingLevel requests ride any
    # outgoing reply; the session layer drains + applies them (firing
    # model_select / thinking_level_select exactly once per change).
    msel = payload.get("model_select", "");
    if msel {
        bridge.pending_model = str(msel);
    }
    tlsel = payload.get("thinking_level_select", "");
    if tlsel {
        bridge.pending_thinking_level = str(tlsel);
    }
}


"""Shortcut bindings registered by loaded extensions (key -> meta dict with
description + extension_id). Listed for host UIs; not yet bound to keys."""
def list_shortcuts(bridge: PluginBridge | None) -> dict[str, any] {
    if bridge is None {
        return {};
    }
    return dict(bridge.shortcuts);
}


"""Labels set by loaded extensions via pi.setLabel (id -> meta dict)."""
def list_labels(bridge: PluginBridge | None) -> dict[str, any] {
    if bridge is None {
        return {};
    }
    return dict(bridge.labels);
}


"""Drain pending extension setModel/setThinkingLevel requests.

Returns {"model": str, "thinking_level": str} and clears both pendings so
each request applies exactly once. Empty strings mean no request."""
def drain_model_requests(bridge: PluginBridge | None) -> dict[str, any] {
    out: dict[str, any] = {"model": "", "thinking_level": ""};
    if bridge is None {
        return out;
    }
    out["model"] = bridge.pending_model;
    out["thinking_level"] = bridge.pending_thinking_level;
    bridge.pending_model = "";
    bridge.pending_thinking_level = "";
    return out;
}


"""Pull per-listener ui_events buckets out of hook results."""
def _absorb_pending_fake(bridge: PluginBridge, h: FakePluginHost) {
    if h.pending_messages {
        msgs = h.pending_messages;
        h.pending_messages = [];
        _absorb_payload(bridge, {"messages": msgs});
    }
    if h.pending_entries {
        ents = h.pending_entries;
        h.pending_entries = [];
        _absorb_payload(bridge, {"entries": ents});
    }
}


"""Fire a lifecycle hook. Returns the per-listener results list from the
hook_done payload: [{ok, extension_id, result|error, verdict?,
notifications?, ui_events?}] where verdict carries the handler's raw object
return when it returned a dict ({block}, {action}, {systemPrompt}, ...).
