"""Fake in-process plugin host — unit-test-only mirror of pi_shim.mjs.

Extracted from agent/plugin_bridge.jac: everything here exists ONLY for the
test path, an in-Jac stand-in for plugin_host/pi_shim.mjs used while no Node
sidecar is running. Import direction is one-way (plugin_bridge -> fake_host
-> protocol) so runtime imports of plugin_bridge stay unchanged.
"""

import time;

import from .protocol {
    Envelope,
    make_envelope,
}

# Mirror of plugin_host/pi_shim.mjs HOST_CAPS / COMPAT_TIER: the fake host
# advertises the same surfaces in its host_hello as the real shim so the
# bridge derives identical capability state from either hello.
glob FAKE_HOST_CAPS: list[str] = [
         "tools",
         "cancel",
         "updates",
         "commands",
         "session_hooks",
         "transformers",
         "providers",
         "renderers",
     ],
     FAKE_COMPAT_TIER: str = "T2-partial";


obj FakePluginHost {
    has handlers: dict[str, any] = {},
        command_handlers: dict[str, any] = {},
        shortcut_handlers: dict[str, any] = {},
        listeners: dict[str, list] = {},
        md_transformers: list = [],
        pending_messages: list = [],
        pending_entries: list = [],
        active_tools: any = None,
        session_name: str = "",
        providers: dict = {},
        message_renderers: dict = {},
        entry_renderers: dict = {},
        extension_tools: dict[str, list[str]] = {},
        cancelled: set[str] = set(),
        node_version: str = "fake",
        alive: bool = True,
        caps: list[str] = list(FAKE_HOST_CAPS),
        compat_tier: str = FAKE_COMPAT_TIER;
}


def create_fake_host(node_version: str = "fake") -> FakePluginHost {
    return FakePluginHost(node_version=node_version);
}


"""Mark bridge activity (resets idle reap clock)."""
def touch_bridge(bridge: any) {
    bridge.last_active = time.monotonic();
    if bridge.status_phase in ("idle", "ready", "") {
        bridge.status_phase = "ready";
    }
}


"""Apply host_hello payload onto bridge capability fields (P4).

Caps/tier are DERIVED from the received hello — never hand-copied constants."""
def apply_hello(bridge: any, hello: Envelope) {
    payload = hello.payload if hello.payload is not None else {};
    bridge.hello_payload = dict(payload);
    raw_caps: any = payload.get("caps", []);
    caps: list = [];
    if isinstance(raw_caps, list) {
        caps = [str(c) for c in raw_caps];
    }
    bridge.host_caps = caps;
    tier = str(payload.get("compat", "") or "");
    if not tier {
        if "cancel" in caps or "updates" in caps {
            tier = "T1";
        } else {
            tier = "T0";
        }
    }
    bridge.compat_tier = tier;
}


"""Attach an in-process host (lazy ensure). Emits host_hello into inbox.

Hello shape matches plugin_host/host.mjs byte-for-byte in structure:
{protocol, node, caps, compat, compat_label}."""
def ensure_host(bridge: any, host: FakePluginHost | None = None) -> str {
    if (
        bridge.host_kind == "node"
        and bridge.proc is not None
        and bridge.proc.poll() is None
    ) {
        return "ready";
    }
    if bridge.host is not None and bridge.host.alive {
        return "ready";
    }
    h = host if host is not None else create_fake_host();
    bridge.host = h;
    bridge.host_kind = "fake";
    h.alive = True;
    hello = make_envelope(
        kind="host_hello",
        session_id=bridge.session_id,
        payload={
            "protocol": 1,
            "node": h.node_version,
            "caps": list(h.caps),
            "compat": h.compat_tier,
            "compat_label": "Pi tool-extension compatibility",
        },
    );
    bridge.inbox.append(hello);
    apply_hello(bridge, hello);
    touch_bridge(bridge);
    bridge.status_phase = "ready";
    return "ready";
}


# ---- fake-host registrations (unit-test parity for the JS API surface) ----

"""Register a command handler on the FAKE host (unit-test path)."""
def register_fake_command(
    bridge: any,
    name: str,
    handler: any,
    description: str = "",
    extension_id: str = "fake.commands",
) {
    ensure_host(bridge);
    h = bridge.host;
    if h is None {
        raise RuntimeError("plugin host unavailable");
    }
    h.command_handlers[name] = {"handler": handler, "owner": extension_id};
    bridge.commands[name] = {
        "name": name,
        "description": description,
        "extension_id": extension_id,
    };
}


def register_fake_shortcut(
    bridge: any,
    key: str,
    handler: any,
    description: str = "",
    extension_id: str = "fake.shortcuts",
) {
    ensure_host(bridge);
    h = bridge.host;
    if h is None {
        raise RuntimeError("plugin host unavailable");
    }
    h.shortcut_handlers[key] = {"handler": handler, "owner": extension_id};
    bridge.shortcuts[key] = {
        "key": key,
        "description": description,
        "extension_id": extension_id,
    };
}


"""Register a lifecycle listener on the FAKE host (unit-test path)."""
def register_fake_listener(bridge: any, event: str, handler: any) {
    ensure_host(bridge);
    h = bridge.host;
    if h is None {
        raise RuntimeError("plugin host unavailable");
    }
    if event not in h.listeners {
        h.listeners[event] = [];
    }
    h.listeners[event].append(handler);
}


"""Register a markdown transformer on the FAKE host (unit-test path)."""
def register_fake_transformer(
    bridge: any,
    fn: any,
    extension_id: str = "fake.xform",
) {
    ensure_host(bridge);
    h = bridge.host;
    if h is None {
        raise RuntimeError("plugin host unavailable");
    }
    entry = {"fn": fn, "extension_id": extension_id};
    h.md_transformers.append(entry);
    bridge.md_transformers.append(entry);
}


"""Register a provider on the FAKE host (unit-test parity for registerProvider)."""
def register_fake_provider(bridge: any, cfg: dict, extension_id: str = "fake.provider") {
    ensure_host(bridge);
    name = str(cfg.get("name", ""));
    if not name {
        raise ValueError("provider config requires a name");
    }
    h = bridge.host;
    entry = dict(cfg);
    if h is not None {
        h.providers[name] = {**entry, "owner": extension_id};
    }
    entry["extension_id"] = extension_id;
    bridge.providers[name] = entry;
}


"""Register a renderer on the FAKE host (unit-test parity)."""
def register_fake_renderer(
    bridge: any,
    kind: str,
    type: str,
    fn: any,
    extension_id: str = "fake.renderer",
) {
    ensure_host(bridge);
    h = bridge.host;
    if h is None {
        raise RuntimeError("plugin host unavailable");
    }
    table = h.message_renderers if kind != "entry" else h.entry_renderers;
    table[str(type)] = {"fn": fn, "owner": extension_id};
}


def fake_push_message(bridge: any, role: str, content: str) {
    ensure_host(bridge);
    h = bridge.host;
    if h is not None {
        h.pending_messages.append({"role": role, "content": content});
    }
}


def fake_push_entry(bridge: any, type: str, data: dict) {
    ensure_host(bridge);
    h = bridge.host;
    if h is not None {
        h.pending_entries.append({"type": type, "data": data});
    }
}


def set_fake_active_tools(bridge: any, names: list | None) {
    ensure_host(bridge);
    h = bridge.host;
    if h is not None {
        h.active_tools = list(names) if names is not None else None;
    }
}


def fake_session_name(bridge: any) -> str {
    return str(bridge.session_name);
}


"""Minimal UI surface handed to fake-host handlers; collects notifications
and display-method ui_events (parity with the JS makeUi surface)."""
obj FakeUi {
    has notifications: list[str],
        ui_events: list;

    def notify(message: str, level: str = "info") {
        self.notifications.append(str(message));
    }

    def _record(method: str, args: list) {
        self.ui_events.append({"method": method, "args": args});
    }

    def set_status(owner: str, text: str) {
        self._record("setStatus", [text]);
    }

    def set_widget(id: str, text: str) {
        self._record("setWidget", [id, text]);
    }

    def set_footer(text: str) {
        self._record("setFooter", [text]);
    }

    def set_title(text: str) {
        self._record("setTitle", [text]);
    }

    def select(_title: str, _options: list) -> any {
        return None;
    }

    def confirm(_message: str) -> bool {
        return False;
    }

    def input(_message: str, _default: str = "") -> str {
        return "";
    }
}
