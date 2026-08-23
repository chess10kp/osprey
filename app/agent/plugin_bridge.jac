"""Plugin bridge — fake in-process host + Node sidecar (D11/D13/D21).

Speaks the same Envelope types as agent.protocol. Session may warm Node in
parallel with the first frame; undeclared installs never start Node.
Async stdout reader + correlation map multiplex replies (P3).
"""

import json;
import os;
import queue;
import shutil;
import subprocess;
import threading;
import time;

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

# Host capability tiers advertised in host_hello (P4).
glob HOST_CAPS_T0: list[str] = ["tools"],
     HOST_CAPS_T1: list[str] = ["tools", "cancel", "updates"],
     COMPAT_TIER: str = "T0";


obj FakePluginHost {
    has handlers: dict[str, any] = {},
        command_handlers: dict[str, any] = {},
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
        alive: bool = True;
}


obj PluginBridge {
    has session_id: str = "",
        host: FakePluginHost | None = None,
        host_kind: str = "",
        proc: any = None,
        node_bin: str = "node",
        host_mjs: str = "",
        next_corr: int = 1,
        outbox: list[Envelope] = [],
        inbox: list[Envelope] = [],
        last_active: float = 0.0,
        status_phase: str = "idle",
        idle_timeout_s: float = 300.0,
        pending: dict = {},
        reply_q: any = None,
        reader_stop: any = None,
        reader_thread: any = None,
        write_lock: any = None,
        restart_used: bool = False,
        host_caps: list = [],
        compat_tier: str = "T0",
        hello_payload: dict = {},
        commands: dict = {},
        md_transformers: list = [],
        providers: dict = {},
        traffic_messages: list = [],
        traffic_entries: list = [],
        session_name: str = "";

    """Dispatch a js tool (fake or Node) — used by registry.invoke."""
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


"""Resolve plugin_host/host.mjs from cwd (app/ or repo root)."""
def resolve_host_mjs(explicit: str = "") -> str {
    if explicit {
        if os.path.isfile(explicit) {
            return os.path.abspath(explicit);
        }
        raise FileNotFoundError(f"host.mjs not found: {explicit}");
    }
    cwd = os.getcwd();
    candidates = [
        os.path.join(cwd, "plugin_host", "host.mjs"),
        os.path.join(cwd, "app", "plugin_host", "host.mjs"),
    ];
    here = os.path.dirname(os.path.abspath(__file__));
    candidates.append(os.path.join(here, "..", "plugin_host", "host.mjs"));
    for c in candidates {
        if os.path.isfile(c) {
            return os.path.abspath(c);
        }
    }
    raise FileNotFoundError("plugin_host/host.mjs not found (run from app/ or repo root)");
}


"""Resolve fixtures/stub_echo.mjs beside the host."""
def resolve_stub_echo(explicit: str = "") -> str {
    if explicit {
        if os.path.isfile(explicit) {
            return os.path.abspath(explicit);
        }
        raise FileNotFoundError(f"stub_echo not found: {explicit}");
    }
    host = resolve_host_mjs();
    path = os.path.join(os.path.dirname(host), "fixtures", "stub_echo.mjs");
    if not os.path.isfile(path) {
        raise FileNotFoundError(f"stub_echo fixture missing: {path}");
    }
    return path;
}
def resolve_pi_greet(explicit: str = "") -> str {
    if explicit {
        if os.path.isfile(explicit) {
            return os.path.abspath(explicit);
        }
        raise FileNotFoundError(f"pi_greet not found: {explicit}");
    }
    host = resolve_host_mjs();
    path = os.path.join(os.path.dirname(host), "fixtures", "pi_greet.mjs");
    if not os.path.isfile(path) {
        raise FileNotFoundError(f"pi_greet fixture missing: {path}");
    }
    return path;
}


def resolve_stub_commands(explicit: str = "") -> str {
    if explicit {
        if os.path.isfile(explicit) {
            return os.path.abspath(explicit);
        }
        raise FileNotFoundError(f"stub_commands not found: {explicit}");
    }
    host = resolve_host_mjs();
    path = os.path.join(os.path.dirname(host), "fixtures", "stub_commands.mjs");
    if not os.path.isfile(path) {
        raise FileNotFoundError(f"stub_commands fixture missing: {path}");
    }
    return path;
}

def resolve_pi_gated(explicit: str = "") -> str {
    if explicit {
        if os.path.isfile(explicit) {
            return os.path.abspath(explicit);
        }
        raise FileNotFoundError(f"pi_gated not found: {explicit}");
    }
    host = resolve_host_mjs();
    path = os.path.join(os.path.dirname(host), "fixtures", "pi_gated.mjs");
    if not os.path.isfile(path) {
        raise FileNotFoundError(f"pi_gated fixture missing: {path}");
    }
    return path;
}


"""Resolve Node binary for the sidecar (P5 packaging).

Order:
1. explicit argument
2. JACKAL_NODE_BIN env
3. pinned sidecar under plugin_host/node/bin/node (or .node-bin)
4. `node` on PATH
"""
def resolve_node_bin(explicit: str = "") -> str {
    if explicit {
        return explicit;
    }
    env = os.environ.get("JACKAL_NODE_BIN", "");
    if env {
        return env;
    }
    try {
        host = resolve_host_mjs();
        host_dir = os.path.dirname(host);
        pinned = [
            os.path.join(host_dir, "node", "bin", "node"),
            os.path.join(host_dir, ".node-bin"),
        ];
        for p in pinned {
            if os.path.isfile(p) {
                return p;
            }
        }
    } except FileNotFoundError {
    }
    which = shutil.which("node");
    if which {
        return which;
    }
    return "node";
}




def envelope_to_dict(env: Envelope) -> dict {
    return {
        "version": env.version,
        "session_id": env.session_id,
        "request_id": env.request_id,
        "turn_id": env.turn_id,
        "tool_id": env.tool_id,
        "sequence": env.sequence,
        "correlation_id": env.correlation_id,
        "kind": env.kind,
        "payload": env.payload if env.payload is not None else {},
    };
}


def envelope_from_dict(data: dict) -> Envelope {
    raw_payload: any = data.get("payload", {});
    payload: dict = {};
    if isinstance(raw_payload, dict) {
        payload = raw_payload;
    }
    return make_envelope(
        kind=str(data.get("kind", "")),
        payload=payload,
        session_id=str(data.get("session_id", "")),
        request_id=str(data.get("request_id", "")),
        turn_id=str(data.get("turn_id", "")),
        tool_id=str(data.get("tool_id", "")),
        sequence=int(data.get("sequence", 0)),
        correlation_id=str(data.get("correlation_id", "")),
        version=int(data.get("version", 1)),
    );
}


def _alloc_corr(bridge: PluginBridge) -> str {
    corr = "corr-" + str(bridge.next_corr);
    bridge.next_corr += 1;
    return corr;
}


def _node_alive(bridge: PluginBridge) -> bool {
    if bridge.host_kind != "node" or bridge.proc is None {
        return False;
    }
    return bridge.proc.poll() is None;
}


"""Mark bridge activity (resets idle reap clock)."""
def _touch(bridge: PluginBridge) {
    bridge.last_active = time.monotonic();
    if bridge.status_phase in ("idle", "ready", "") {
        bridge.status_phase = "ready";
    }
}


"""Push host_status into inbox and record phase (D13 degraded visibility)."""
def _emit_host_status(bridge: PluginBridge, phase: str, detail: str = "") {
    bridge.status_phase = phase;
    bridge.inbox.append(
        make_envelope(
            kind="host_status",
            session_id=bridge.session_id,
            payload={"phase": phase, "detail": detail},
        )
    );
}


"""Inspect host health. Dead Node → degraded status envelope; returns phase."""
def host_status(bridge: PluginBridge) -> str {
    if bridge.host_kind == "node" {
        if bridge.proc is not None and not _node_alive(bridge) {
            if bridge.status_phase != "dead" {
                _emit_host_status(bridge, "degraded", "node host exited unexpectedly");
                bridge.host_kind = "";
                bridge.proc = None;
            }
        }
    } elif bridge.host_kind == "fake" {
        h = bridge.host;
        if h is None or not h.alive {
            if bridge.status_phase != "dead" {
                _emit_host_status(bridge, "degraded", "fake host unavailable");
            }
        }
    }
    return bridge.status_phase if bridge.status_phase else "idle";
}


"""Reap Node host after idle_timeout_s with no activity. Returns True if reaped."""
def maybe_reap_idle(
    bridge: PluginBridge, idle_timeout_s: float = -1.0, now: float = -1.0
) -> bool {
    if bridge.host_kind != "node" or not _node_alive(bridge) {
        # Still surface unexpected death.
        host_status(bridge);
        return False;
    }
    timeout = idle_timeout_s if idle_timeout_s >= 0.0 else bridge.idle_timeout_s;
    if timeout <= 0.0 {
        return False;
    }
    ts = now if now >= 0.0 else time.monotonic();
    last = bridge.last_active;
    if last <= 0.0 {
        last = ts;
        bridge.last_active = ts;
    }
    if (ts - last) < timeout {
        return False;
    }
    _emit_host_status(bridge, "dead", f"idle reap after {timeout}s");
    dispose_bridge(bridge);
    bridge.status_phase = "dead";
    return True;
}


def _write_node(bridge: PluginBridge, env: Envelope) {
    if not _node_alive(bridge) {
        raise RuntimeError("plugin node host not running");
    }
    line = json.dumps(envelope_to_dict(env)) + "\n";
    lock: any = bridge.write_lock;
    if lock is not None {
        lock.acquire();
        try {
            bridge.proc.stdin.write(line);
            bridge.proc.stdin.flush();
        } finally {
            lock.release();
        }
    } else {
        bridge.proc.stdin.write(line);
        bridge.proc.stdin.flush();
    }
    bridge.outbox.append(env);
}


"""Route an inbound envelope to a pending waiter; always keep a copy in inbox."""
def _dispatch_inbound(bridge: PluginBridge, env: Envelope) {
    bridge.inbox.append(env);
    corr = env.correlation_id;
    pending = bridge.pending;
    if corr and corr in pending {
        waiter: any = pending[corr];
        waiter["env"] = env;
        ev: any = waiter.get("event");
        if ev is not None {
            ev.set();
        }
    }
}


"""Background stdout reader — multiplexes replies by correlation_id (P3)."""
def _reader_loop(bridge: PluginBridge) {
    stop = bridge.reader_stop;
    proc = bridge.proc;
    if proc is None {
        return;
    }
    stdout = proc.stdout;
    while stop is None or not stop.is_set() {
        try {
            line_raw: any = stdout.readline();
        } except Exception {
            break;
        }
        if not line_raw {
            break;
        }
        line_s: str = str(line_raw).strip();
        if not line_s {
            continue;
        }
        try {
            parsed: any = json.loads(line_s);
        } except Exception {
            bridge.inbox.append(
                make_envelope(
                    kind="host_status",
                    session_id=bridge.session_id,
                    payload={"phase": "degraded", "detail": "bad json from host"},
                )
            );
            continue;
        }
        if not isinstance(parsed, dict) {
            continue;
        }
        env = envelope_from_dict(parsed);
        _dispatch_inbound(bridge, env);
    }
}


def _ensure_io(bridge: PluginBridge) {
    if bridge.reply_q is None {
        bridge.reply_q = queue.Queue();
    }
    if bridge.write_lock is None {
        bridge.write_lock = threading.Lock();
    }
    if bridge.reader_stop is None {
        bridge.reader_stop = threading.Event();
    }
    if bridge.pending is None {
        bridge.pending = {};
    }
}


def _start_reader(bridge: PluginBridge) {
    _ensure_io(bridge);
    if bridge.reader_thread is not None and bridge.reader_thread.is_alive() {
        return;
    }
    bridge.reader_stop.clear();
    t = threading.Thread(
        target=_reader_loop, args=(bridge,), daemon=True, name="plugin-host-reader"
    );
    bridge.reader_thread = t;
    t.start();
}


def _stop_reader(bridge: PluginBridge) {
    if bridge.reader_stop is not None {
        bridge.reader_stop.set();
    }
    bridge.reader_thread = None;
}


"""Wait for a correlated reply (or any matching kind if corr empty).

Callers that write a request MUST register `correlation_id` in
`bridge.pending` *before* `_write_node` (or call `_prepare_corr`) so the
reader cannot win the race.
"""
def _prepare_corr(bridge: PluginBridge, correlation_id: str) {
    _ensure_io(bridge);
    if correlation_id and correlation_id not in bridge.pending {
        bridge.pending[correlation_id] = {
            "event": threading.Event(),
            "env": None,
        };
    }
}


def _wait_corr(
    bridge: PluginBridge,
    kind: str,
    correlation_id: str = "",
    timeout: float = 5.0,
) -> Envelope {
    deadline = time.monotonic() + timeout;
    if correlation_id {
        _prepare_corr(bridge, correlation_id);
        waiter: any = bridge.pending[correlation_id];
        if waiter.get("env") is not None {
            bridge.pending.pop(correlation_id, None);
            got: any = waiter["env"];
            return got as Envelope;
        }
        remaining = max(0.01, deadline - time.monotonic());
        ok = waiter["event"].wait(timeout=remaining);
        done = bridge.pending.pop(correlation_id, None);
        if not ok or done is None or done.get("env") is None {
            raise TimeoutError(f"timed out waiting for {kind}");
        }
        got2: any = done["env"];
        return got2 as Envelope;
    }
    # No corr: poll inbox for kind (do not remove — drain_inbox owns removal).
    while time.monotonic() < deadline {
        host_status(bridge);
        for i in range(len(bridge.inbox)) {
            env = bridge.inbox[i];
            if not kind or env.kind == kind {
                return env;
            }
        }
        time.sleep(0.02);
    }
    raise TimeoutError(f"timed out waiting for {kind}");
}


def _read_node(bridge: PluginBridge, timeout: float = 5.0) -> Envelope {
    return _wait_corr(bridge, "", "", timeout=timeout);
}


"""Read until an envelope with kind matches (or timeout)."""
def _read_node_until(
    bridge: PluginBridge, kind: str, correlation_id: str = "", timeout: float = 5.0
) -> Envelope {
    if correlation_id {
        env = _wait_corr(bridge, kind, correlation_id, timeout=timeout);
        if env.kind != kind {
            raise TimeoutError(f"timed out waiting for {kind}");
        }
        return env;
    }
    deadline = time.monotonic() + timeout;
    while time.monotonic() < deadline {
        remaining = max(0.05, deadline - time.monotonic());
        try {
            env = _wait_corr(bridge, kind, "", timeout=remaining);
            if env.kind == kind {
                return env;
            }
            bridge.inbox.append(env);
        } except TimeoutError {
            break;
        }
    }
    raise TimeoutError(f"timed out waiting for {kind}");
}


"""Attach an in-process host (lazy ensure). Emits host_hello into inbox."""
def ensure_host(bridge: PluginBridge, host: FakePluginHost | None = None) -> str {
    if bridge.host_kind == "node" and _node_alive(bridge) {
        return "ready";
    }
    if bridge.host is not None and bridge.host.alive {
        return "ready";
    }
    h = host if host is not None else create_fake_host();
    bridge.host = h;
    bridge.host_kind = "fake";
    h.alive = True;
    caps = list(HOST_CAPS_T0);
    bridge.host_caps = caps;
    bridge.compat_tier = "T0";
    bridge.hello_payload = {
        "protocol": 1,
        "node": h.node_version,
        "caps": caps,
        "compat": "T0",
        "compat_label": "Pi tool-extension compatibility",
    };
    bridge.inbox.append(
        make_envelope(
            kind="host_hello",
            session_id=bridge.session_id,
            payload=bridge.hello_payload,
        )
    );
    _touch(bridge);
    bridge.status_phase = "ready";
    return "ready";
}


"""Apply host_hello payload onto bridge capability fields (P4)."""
def _apply_hello(bridge: PluginBridge, hello: Envelope) {
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


"""Spawn the Node plugin host. Emits host_hello from the child."""
def ensure_node_host(
    bridge: PluginBridge,
    host_mjs: str = "",
    node_bin: str = "",
    timeout: float = 5.0,
) -> str {
    if _node_alive(bridge) {
        return "ready";
    }
    if bridge.host is not None {
        bridge.host.alive = False;
        bridge.host = None;
    }
    path = resolve_host_mjs(host_mjs);
    bridge.host_mjs = path;
    bin_path = node_bin if node_bin else resolve_node_bin();
    bridge.node_bin = bin_path;
    _emit_host_status(bridge, "starting", "spawning node sidecar");
    _ensure_io(bridge);
    bridge.proc = subprocess.Popen(
        [bin_path, path],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    );
    bridge.host_kind = "node";
    _start_reader(bridge);
    hello = _read_node_until(bridge, "host_hello", timeout=timeout);
    if hello.kind != "host_hello" {
        _emit_host_status(bridge, "degraded", f"expected host_hello, got {hello.kind}");
        dispose_bridge(bridge);
        raise RuntimeError(f"expected host_hello, got {hello.kind}");
    }
    _apply_hello(bridge, hello);
    _touch(bridge);
    bridge.status_phase = "ready";
    return "ready";
}


"""One controlled restart after unexpected host death (P3). Returns phase."""
def maybe_restart_host(bridge: PluginBridge, timeout: float = 5.0) -> str {
    if _node_alive(bridge) {
        return "ready";
    }
    if bridge.restart_used {
        host_status(bridge);
        if bridge.status_phase != "degraded" {
            _emit_host_status(bridge, "degraded", "restart already used");
        }
        return "degraded";
    }
    bridge.restart_used = True;
    old_mjs = bridge.host_mjs;
    old_bin = bridge.node_bin;
    _stop_reader(bridge);
    if bridge.proc is not None {
        try {
            bridge.proc.kill();
        } except Exception {
        }
        bridge.proc = None;
    }
    bridge.host_kind = "";
    bridge.pending = {};
    try {
        return ensure_node_host(
            bridge, host_mjs=old_mjs, node_bin=old_bin, timeout=timeout
        );
    } except Exception as e {
        _emit_host_status(bridge, "degraded", f"restart failed: {e}");
        return "degraded";
    }
}


def dispose_bridge(bridge: PluginBridge) {
    if bridge.host_kind == "node" and bridge.proc is not None {
        try {
            if bridge.proc.poll() is None {
                bye = make_envelope(
                    kind="host_goodbye",
                    session_id=bridge.session_id,
                    payload={"reason": "dispose"},
                );
                try {
                    _write_node(bridge, bye);
                    _read_node_until(bridge, "host_goodbye", timeout=2.0);
                } except Exception {
                }
                bridge.proc.terminate();
                try {
                    bridge.proc.wait(timeout=2.0);
                } except subprocess.TimeoutExpired {
                    bridge.proc.kill();
                    bridge.proc.wait(timeout=2.0);
                }
            }
        } except Exception {
        }
        _stop_reader(bridge);
        bridge.proc = None;
        bridge.host_kind = "";
        bridge.pending = {};
        bridge.inbox.append(
            make_envelope(
                kind="host_goodbye",
                session_id=bridge.session_id,
                payload={"reason": "dispose"},
            )
        );
        bridge.outbox.clear();
        return;
    }
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
    bridge.host_kind = "";
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
        raw_params: any = t.get("parameters", {});
        params: dict = {};
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
    if bridge.outbox {
        bridge.outbox.pop(0);
    }
    _touch(bridge);
    return names;
}


"""Return (ok, missing) for required capabilities vs host_caps (P4)."""
def caps_satisfied(bridge: PluginBridge, requires: list) -> list {
    missing: list[str] = [];
    for r in requires {
        need = str(r);
        if need and need not in bridge.host_caps {
            missing.append(need);
        }
    }
    return [len(missing) == 0, missing];
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
    requires: list = [],
) -> list[str] {
    ensure_node_host(bridge);
    cap_check = caps_satisfied(bridge, requires);
    ok_caps: bool = bool(cap_check[0]);
    missing: list = [];
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
    abs_path = os.path.abspath(path);
    if not os.path.isfile(abs_path) {
        raise FileNotFoundError(f"extension module not found: {abs_path}");
    }
    corr = _alloc_corr(bridge);
    _prepare_corr(bridge, corr);
    req = make_envelope(
        kind="ext_load",
        session_id=bridge.session_id,
        correlation_id=corr,
        payload={
            "id": extension_id,
            "path": abs_path,
            "requires": [str(x) for x in requires],
        },
    );
    _write_node(bridge, req);
    if bridge.outbox {
        bridge.outbox.pop(0);
    }
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
        params: dict = {};
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
    cmds: list = reply.payload.get("commands", []);
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
    _touch(bridge);
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
    if bridge.host_kind == "node" and _node_alive(bridge) {
        req = make_envelope(
            kind="ext_unload",
            session_id=bridge.session_id,
            payload={"id": extension_id},
        );
        try {
            _write_node(bridge, req);
            if bridge.outbox {
                bridge.outbox.pop(0);
            }
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


"""Invoke a js tool via tool_invoke / tool_result (fake or Node)."""
def invoke_tool(bridge: PluginBridge, name: str, args: dict) -> str {
    # Surface dead Node before attempting RPC (D13 degraded, never crash).
    if bridge.host_kind == "node" and not _node_alive(bridge) {
        host_status(bridge);
        return "ERROR: plugin host unavailable";
    }
    if bridge.host_kind == "node" {
        result = _invoke_tool_node(bridge, name, args);
    } else {
        result = _invoke_tool_fake(bridge, name, args);
    }
    if not str(result).startswith("ERROR: plugin host unavailable") {
        _touch(bridge);
    } elif bridge.host_kind == "node" {
        host_status(bridge);
    }
    return result;
}


def _invoke_tool_fake(bridge: PluginBridge, name: str, args: dict) -> str {
    ensure_host(bridge);
    h = bridge.host;
    if h is None or not h.alive {
        return "ERROR: plugin host unavailable";
    }
    corr = _alloc_corr(bridge);
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
    # Fake-host parity for active-tool enforcement (B1).
    if h.active_tools is not None and name not in h.active_tools {
        bridge.outbox.pop(0);
        bridge.inbox.append(
            make_envelope(
                kind="tool_result",
                session_id=bridge.session_id,
                tool_id=name,
                correlation_id=corr,
                payload={"ok": False, "error": f"tool {name} is not active"},
            )
        );
        return f"ERROR: tool {name} is not active";
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
    payload: dict = {"ok": ok};
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


def _invoke_tool_node(bridge: PluginBridge, name: str, args: dict) -> str {
    if not _node_alive(bridge) {
        phase = maybe_restart_host(bridge);
        if phase != "ready" or not _node_alive(bridge) {
            return "ERROR: plugin host unavailable";
        }
    }
    corr = _alloc_corr(bridge);
    _prepare_corr(bridge, corr);
    req = make_envelope(
        kind="tool_invoke",
        session_id=bridge.session_id,
        tool_id=name,
        correlation_id=corr,
        payload={"name": name, "args": args},
    );
    try {
        _write_node(bridge, req);
        if bridge.outbox {
            bridge.outbox.pop(0);
        }
        reply = _read_node_until(
            bridge, "tool_result", correlation_id=corr, timeout=10.0
        );
    } except Exception as e {
        return f"ERROR: {e}";
    }
    ok = bool(reply.payload.get("ok", False));
    _absorb_payload(bridge, dict(reply.payload));
    if ok {
        return str(reply.payload.get("result", ""));
    }
    return f"ERROR: {reply.payload.get('error', 'invoke failed')}";
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


# ======================= T2-partial: commands + hooks =======================

"""Register a command handler on the FAKE host (unit-test path)."""
def register_fake_command(
    bridge: PluginBridge,
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


"""Register a lifecycle listener on the FAKE host (unit-test path)."""
def register_fake_listener(bridge: PluginBridge, event: str, handler: any) {
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


"""Invoke an extension command. Returns the cmd_result payload dict:
{ok, result?, error?, notifications?}. Raises TimeoutError on Node silence."""
def invoke_command(
    bridge: PluginBridge, name: str, args: str = "", timeout: float = 10.0
) -> dict {
    if bridge.host_kind == "node" {
        if not _node_alive(bridge) {
            phase = maybe_restart_host(bridge);
            if phase != "ready" or not _node_alive(bridge) {
                host_status(bridge);
                return {"ok": False, "error": "plugin host unavailable"};
            }
        }
        corr = _alloc_corr(bridge);
        _prepare_corr(bridge, corr);
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
        _touch(bridge);
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
    entry = h.command_handlers.get(name);
    if entry is None {
        return {"ok": False, "error": f"unknown command {name}"};
    }
    notifications: list[str] = [];
    try {
        ui = FakeUi(notifications, []);
        result = entry["handler"](args, {"ui": ui});
        res_payload: dict = {
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
        err_payload: dict = {
            "ok": False,
            "error": str(e),
            "notifications": notifications,
        };
        _absorb_pending_fake(bridge, h);
        return err_payload;
    }
}


"""Absorb extension traffic (message pushes, entries, ui_events, session
name) from a reply payload into bridge tracking buffers. Tolerates junk."""
def _absorb_payload(bridge: PluginBridge, payload: dict) {
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
}


"""Pull per-listener ui_events buckets out of hook results."""
def _absorb_hook_results(bridge: PluginBridge, results: list) {
    for r in results {
        if isinstance(r, dict) and r.get("ui_events") {
            _absorb_payload(bridge, {"ui_events": r["ui_events"]});
        }
    }
}

# ===================== batch-2 events + structured verdicts =====================

"""Fire a hook and return (results, final_data).

For `tool_call` / `context` the host hands handlers a deep copy they mutate
IN PLACE (later handlers see earlier mutations — Pi semantics) and echoes the
final working copy back as hook_done payload `data`. Other events return
`data` unchanged. Results entries carry `verdict`: the handler's raw object
return ({block}, {action}, {messages}, ...) or None for scalar/None returns.
Returns {results, data}; never raises on transport failure (empty results)."""
def fire_hook_data(
    bridge: PluginBridge | None, event: str, data: dict, timeout: float = 10.0
) -> dict {
    empty: dict = {"results": [], "data": dict(data)};
    if bridge is None {
        return empty;
    }
    if bridge.host_kind == "node" and _node_alive(bridge) {
        corr = _alloc_corr(bridge);
        _prepare_corr(bridge, corr);
        req = make_envelope(
            kind="hook_fire",
            session_id=bridge.session_id,
            correlation_id=corr,
            payload={"event": event, "data": data},
        );
        try {
            _write_node(bridge, req);
            reply = _read_node_until(
                bridge, "hook_done", correlation_id=corr, timeout=timeout
            );
        } except Exception {
            return empty;
        }
        _touch(bridge);
        raw: any = reply.payload.get("results", []);
        out_list: list = raw if isinstance(raw, list) else [];
        final: any = reply.payload.get("data");
        final_data: dict = dict(final) if isinstance(final, dict) else dict(data);
        _absorb_payload(bridge, dict(reply.payload));
        _absorb_hook_results(bridge, out_list);
        return {"results": out_list, "data": final_data};
    }
    # Fake host path: handlers receive the live dict; Python mutations are
    # visible to later handlers directly (in-place chaining for free).
    h = bridge.host;
    if h is None or not h.alive {
        return empty;
    }
    working = dict(data);
    results: list = [];
    for handler in h.listeners.get(event, []) {
        notifications: list[str] = [];
        try {
            ui = FakeUi(notifications, []);
            out = handler(working, {"ui": ui});
            # Transform verdicts rewrite the working text so later handlers
            # see the composed input (Pi input-transform chaining).
            if (
                isinstance(out, dict)
                and str(out.get("action")) == "transform"
                and out.get("text") is not None
            ) {
                working["text"] = str(out.get("text"));
            }
            entry_r: dict = {
                "ok": True,
                "result": "" if out is None else str(out),
                "verdict": out if isinstance(out, dict) else None,
                "notifications": notifications,
            };
            if ui.ui_events {
                entry_r["ui_events"] = list(ui.ui_events);
            }
            results.append(entry_r);
        } except Exception as e {
            results.append({
                "ok": False,
                "error": str(e),
                "verdict": None,
                "notifications": notifications,
            });
        }
    }
    _absorb_pending_fake(bridge, h);
    _absorb_hook_results(bridge, results);
    return {"results": results, "data": working};
}


"""Verdict dicts from successful listener results, in fire order."""
def _ok_verdicts(results: list) -> list {
    verdicts: list = [];
    for r in results {
        if isinstance(r, dict) and r.get("ok") and isinstance(r.get("verdict"), dict) {
            verdicts.append(r["verdict"]);
        }
    }
    return verdicts;
}


"""tool_call gate: fires the Pi `tool_call` hook and aggregates verdicts.

Returns {blocked, reason, terminate, args} where args is the (possibly
handler-mutated) tool input to actually execute with. First blocking handler
wins. Never raises — default verdict lets the call through."""
def tool_call_gate(bridge: PluginBridge | None, name: str, args: dict) -> dict {
    out: dict = {"blocked": False, "reason": "", "terminate": False, "args": args};
    if bridge is None {
        return out;
    }
    data = {"toolName": str(name), "toolCallId": "", "input": args};
    try {
        fired = fire_hook_data(bridge, "tool_call", data);
        results = fired["results"];
        final = fired["data"];
    } except Exception {
        return out;
    }
    mutated: any = final.get("input") if isinstance(final, dict) else None;
    if isinstance(mutated, dict) {
        out["args"] = mutated;
    }
    for v in _ok_verdicts(results) {
        if v.get("block") {
            out["blocked"] = True;
            out["reason"] = str(v.get("reason", ""));
            out["terminate"] = bool(v.get("terminate", False));
            break;
        }
    }
    return out;
}


"""input gate: fires the Pi `input` hook over raw user text.

Returns {action, text} — action is continue | transform | handled (first
handled wins). Transforms CHAIN: hosts apply each transform verdict to the
working copy between handlers, so later handlers and the echoed final text
see the composed result — the echoed text is authoritative."""
def input_gate(bridge: PluginBridge | None, text: str) -> dict {
    out: dict = {"action": "continue", "text": str(text)};
    if bridge is None {
        return out;
    }
    try {
        fired = fire_hook_data(
            bridge, "input", {"text": str(text), "source": "interactive"}
        );
        results = fired.get("results", []);
        final = fired.get("data", {});
    } except Exception {
        return out;
    }
    for v in _ok_verdicts(results) {
        if str(v.get("action", "continue")) == "handled" {
            t: any = final.get("text") if isinstance(final, dict) else None;
            return {
                "action": "handled",
                "text": str(t) if isinstance(t, str) else out["text"],
            };
        }
        if str(v.get("action", "continue")) == "transform" {
            out["action"] = "transform";
        }
    }
    if out["action"] == "transform" and isinstance(final, dict) {
        t2: any = final.get("text");
        if isinstance(t2, str) {
            out["text"] = t2;
        }
    }
    return out;
}


"""context gate: fires the Pi `context` hook before each LLM call.

Handlers may edit the message copy in place (echoed back) or return
{messages} (explicit replacement — last one wins). Returns the message list
to stream with; the caller's history is never mutated."""
def context_gate(bridge: PluginBridge | None, messages: list) -> list {
    if bridge is None {
        return messages;
    }
    try {
        snapshot: any = json.loads(json.dumps(messages));
    } except Exception {
        return messages;
    }
    if not isinstance(snapshot, list) {
        return messages;
    }
    try {
        fired = fire_hook_data(bridge, "context", {"messages": snapshot});
        results = fired["results"];
        final = fired["data"];
    } except Exception {
        return messages;
    }
    replaced: any = None;
    for v in _ok_verdicts(results) {
        if isinstance(v.get("messages"), list) {
            replaced = v["messages"];
        }
    }
    if replaced is not None {
        return replaced;
    }
    echoed: any = final.get("messages") if isinstance(final, dict) else None;
    if isinstance(echoed, list) {
        return echoed;
    }
    return messages;
}


"""before_agent_start gate: aggregate {message, systemPrompt} returns.

systemPrompt composes last-wins across handlers (each handler built its
string from the same base prompt in this single-round-trip design — full
chaining would need per-handler round trips). Message injection keeps the
last non-empty content."""
def agent_start_gate(bridge: PluginBridge | None, prompt: str) -> dict {
    out: dict = {"message": "", "systemPrompt": ""};
    if bridge is None {
        return out;
    }
    try {
        fired = fire_hook_data(
            bridge, "before_agent_start", {"prompt": str(prompt)}
        );
        results = fired["results"];
    } except Exception {
        return out;
    }
    for v in _ok_verdicts(results) {
        sp = v.get("systemPrompt");
        if isinstance(sp, str) and sp {
            out["systemPrompt"] = sp;
        }
        m: any = v.get("message");
        if isinstance(m, dict) and m.get("content") is not None {
            out["message"] = str(m.get("content"));
        } elif isinstance(m, str) and m {
            out["message"] = m;
        }
    }
    return out;
}

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


"""Fire a lifecycle hook. Returns the per-listener results list from the
hook_done payload: [{ok, extension_id, result|error, verdict?,
notifications?, ui_events?}] where verdict carries the handler's raw object
return when it returned a dict ({block}, {action}, {systemPrompt}, ...).
Returns [] when no host exists (hooks are best-effort, never fatal)."""
def fire_hook(bridge: PluginBridge, event: str, data: dict, timeout: float = 10.0) -> list {
    if bridge.host_kind == "node" and _node_alive(bridge) {
        corr = _alloc_corr(bridge);
        _prepare_corr(bridge, corr);
        req = make_envelope(
            kind="hook_fire",
            session_id=bridge.session_id,
            correlation_id=corr,
            payload={"event": event, "data": data},
        );
        try {
            _write_node(bridge, req);
            reply = _read_node_until(
                bridge, "hook_done", correlation_id=corr, timeout=timeout
            );
        } except Exception {
            return [];
        }
        _touch(bridge);
        raw: any = reply.payload.get("results", []);
        out_list: list = raw if isinstance(raw, list) else [];
        _absorb_payload(bridge, dict(reply.payload));
        _absorb_hook_results(bridge, out_list);
        return out_list;
    }
    # Fake host path.
    h = bridge.host;
    if h is None or not h.alive {
        return [];
    }
    results: list = [];
    for handler in h.listeners.get(event, []) {
        notifications: list[str] = [];
        try {
            ui = FakeUi(notifications, []);
            out = handler(data, {"ui": ui});
            entry_r: dict = {
                "ok": True,
                "result": "" if out is None else str(out),
                "verdict": out if isinstance(out, dict) else None,
                "notifications": notifications,
            };
            if ui.ui_events {
                entry_r["ui_events"] = list(ui.ui_events);
            }
            results.append(entry_r);
        } except Exception as e {
            results.append({
                "ok": False,
                "error": str(e),
                "verdict": None,
                "notifications": notifications,
            });
        }
    }
    _absorb_pending_fake(bridge, h);
    _absorb_hook_results(bridge, results);
    return results;
}


# ======================= T2-partial: markdown transformers =======================

"""Register a markdown transformer on the FAKE host (unit-test path)."""
def register_fake_transformer(
    bridge: PluginBridge,
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


"""Run the extension markdown-transformer chain over a complete block.

Display-only (Pi semantics): the session/model context is never mutated.
Returns {"ok": True, "markdown": <transformed>} — transformer errors keep
the output produced so far and never fail the turn. With no host or no
transformers this is an identity passthrough.
"""
def transform_markdown(
    bridge: PluginBridge | None,
    markdown: str,
    message_type: str = "assistant",
    streaming: bool = False,
) -> dict {
    md = str(markdown);
    if bridge is None {
        return {"ok": True, "markdown": md};
    }
    mctx = {"message_type": message_type, "isStreaming": streaming};
    if bridge.host_kind == "node" and _node_alive(bridge) {
        corr = _alloc_corr(bridge);
        _prepare_corr(bridge, corr);
        req = make_envelope(
            kind="md_transform",
            session_id=bridge.session_id,
            correlation_id=corr,
            payload={
                "markdown": md,
                "message_type": message_type,
                "streaming": streaming,
            },
        );
        try {
            _write_node(bridge, req);
            reply = _read_node_until(
                bridge, "md_transformed", correlation_id=corr, timeout=10.0
            );
        } except Exception as e {
            return {"ok": False, "error": str(e), "markdown": md};
        }
        _touch(bridge);
        out = dict(reply.payload);
        out["ok"] = True;
        _absorb_payload(bridge, out);
        return out;
    }
    # Fake host path.
    h = bridge.host;
    if h is None or not h.alive {
        return {"ok": True, "markdown": md};
    }
    for t in h.md_transformers {
        try {
            out: any = t["fn"](md, mctx);
            if isinstance(out, str) {
                md = out;
            }
        } except Exception {
            # Keep prior output, continue the chain.
        }
    }
    return {"ok": True, "markdown": md};
}


# ======================= B1: extension traffic drain + control =======================

"""Pop accumulated extension traffic (messages pushed via sendMessage/
sendUserMessage; entries/ui_events from appendEntry + display UI calls).
Returns {"messages": [...], "entries": [...]} and clears the buffers."""
def drain_extension_traffic(bridge: PluginBridge | None) -> dict {
    if bridge is None {
        return {"messages": [], "entries": []};
    }
    h = bridge.host;
    if h is not None {
        _absorb_pending_fake(bridge, h);
        if h.session_name {
            _absorb_payload(bridge, {"session_name": h.session_name});
        }
    }
    out: dict = {
        "messages": list(bridge.traffic_messages),
        "entries": list(bridge.traffic_entries),
    };
    bridge.traffic_messages.clear();
    bridge.traffic_entries.clear();
    return out;
}


"""Set the host-side session name (round-trips through any envelope)."""
def set_session_name(bridge: PluginBridge, name: str, timeout: float = 5.0) -> bool {
    bridge.session_name = str(name);
    if bridge.host_kind == "node" and _node_alive(bridge) {
        corr = _alloc_corr(bridge);
        _prepare_corr(bridge, corr);
        req = make_envelope(
            kind="hook_fire",
            session_id=bridge.session_id,
            correlation_id=corr,
            payload={"event": "__session_name", "data": {}, "session_name": str(name)},
        );
        try {
            _write_node(bridge, req);
            _read_node_until(
                bridge, "hook_done", correlation_id=corr, timeout=timeout
            );
        } except Exception as e {
            return False;
        }
    }
    h = bridge.host;
    if h is not None {
        h.session_name = str(name);
    }
    return True;
}


# ---- fake-host helpers (unit-test parity for the JS API surface) ----

def fake_push_message(bridge: PluginBridge, role: str, content: str) {
    ensure_host(bridge);
    h = bridge.host;
    if h is not None {
        h.pending_messages.append({"role": role, "content": content});
    }
}


def fake_push_entry(bridge: PluginBridge, type: str, data: dict) {
    ensure_host(bridge);
    h = bridge.host;
    if h is not None {
        h.pending_entries.append({"type": type, "data": data});
    }
}


def set_fake_active_tools(bridge: PluginBridge, names: list | None) {
    ensure_host(bridge);
    h = bridge.host;
    if h is not None {
        h.active_tools = list(names) if names is not None else None;
    }
}


def fake_session_name(bridge: PluginBridge) -> str {
    return str(bridge.session_name);
}


# ============================ P10: provider seam ============================

"""Register a provider on the FAKE host (unit-test parity for registerProvider)."""
def register_fake_provider(bridge: PluginBridge, cfg: dict, extension_id: str = "fake.provider") {
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


"""Resolve an `ext/<extension>/<model>` model id against declared providers.

Returns {provider, model, base_url, streaming} or None when the id does not
match the namespace or no extension declared it."""
def resolve_ext_model(bridge: PluginBridge | None, model_id: str) -> dict | None {
    parts = str(model_id).split("/");
    if len(parts) != 3 or parts[0] != "ext" or not parts[1] or not parts[2] {
        return None;
    }
    if bridge is None {
        return None;
    }
    ext_id = parts[1];
    model = parts[2];
    # Jac parser rejects `for name, cfg in ...` tuple unpacking.
    for name in bridge.providers {
        cfg = bridge.providers[name];
        if str(cfg.get("extension_id", "")) != ext_id {
            continue;
        }
        for m in cfg.get("models", []) or [] {
            mid = m.get("id", "") if isinstance(m, dict) else str(m);
            if str(mid) == model {
                return {
                    "provider": str(name),
                    "model": model,
                    "base_url": str(cfg.get("base_url", "") or ""),
                    "streaming": cfg.get("streaming", True) is not False,
                    "extension_id": ext_id,
                };
            }
        }
    }
    return None;
}


"""P10 request seam: fire Pi's `before_provider_request` hook.

Handlers may edit {model, url, headers, body} in place (echoed back) and/or
return replacements ({body}, {url}, {headers} — last one wins per field).
Full request control is intentional: extensions are trusted in-process code.
Never raises; on any failure the original request passes through."""
def prepare_provider_request(
    bridge: PluginBridge | None,
    model: str,
    url: str,
    headers: dict,
    body: dict,
) -> dict {
    out: dict = {"url": url, "headers": headers, "body": body};
    if bridge is None {
        return out;
    }
    data = {"model": str(model), "url": url, "headers": headers, "body": body};
    try {
        fired = fire_hook_data(bridge, "before_provider_request", data);
    } except Exception {
        return out;
    }
    final = fired.get("data", {}) if isinstance(fired, dict) else {};
    results = fired.get("results", []) if isinstance(fired, dict) else [];
    # In-place edits first (echoed working copy)...
    for key in ("url", "headers", "body") {
        v: any = final.get(key) if isinstance(final, dict) else None;
        if v is not None {
            out[key] = v;
        }
    }
    # ...then explicit verdict replacements override.
    for v in _ok_verdicts(results) {
        u = v.get("url");
        if isinstance(u, str) and u {
            out["url"] = u;
        }
        for key in ("headers", "body") {
            if isinstance(v.get(key), dict) {
                out[key] = v[key];
            }
        }
    }
    return out;
}


"""Register a renderer on the FAKE host (unit-test parity)."""
def register_fake_renderer(
    bridge: PluginBridge,
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


"""Mirror the shim's toContentLines normalization."""
def _fake_content_lines(out: any) -> list {
    if out is None {
        return [];
    }
    if isinstance(out, list) {
        return [str(x) for x in out];
    }
    if isinstance(out, dict) and isinstance(out.get("lines"), list) {
        return [str(x) for x in out["lines"]];
    }
    return [x for x in str(out).split("\n")];
}


"""P11: run an extension message/entry renderer; returns native content
lines ({ok, lines}). Renderer errors degrade to unstyled fallback lines.
No bridge/host/renderer -> {ok: False, lines: []} (caller uses defaults)."""
def render_extension_block(
    bridge: PluginBridge | None, kind: str, type: str, payload: any
) -> dict {
    none_out: dict = {"ok": False, "lines": []};
    if bridge is None {
        return none_out;
    }
    if bridge.host_kind == "node" and _node_alive(bridge) {
        corr = _alloc_corr(bridge);
        _prepare_corr(bridge, corr);
        req = make_envelope(
            kind="render_message",
            session_id=bridge.session_id,
            correlation_id=corr,
            payload={"kind": kind, "type": type, "payload": payload},
        );
        try {
            _write_node(bridge, req);
            reply = _read_node_until(
                bridge, "rendered", correlation_id=corr, timeout=10.0
            );
        } except Exception {
            return none_out;
        }
        _touch(bridge);
        ok = bool(reply.payload.get("ok", False));
        raw: any = reply.payload.get("lines", []);
        lines: list = [str(x) for x in raw] if isinstance(raw, list) else [];
        return {"ok": ok, "lines": lines};
    }
    h = bridge.host;
    if h is None or not h.alive {
        return none_out;
    }
    table = h.message_renderers if kind != "entry" else h.entry_renderers;
    entry: any = table.get(str(type));
    if entry is None or not isinstance(entry, dict) {
        return none_out;
    }
    try {
        out: any = entry["fn"](payload);
        return {"ok": True, "lines": _fake_content_lines(out)};
    } except Exception as e {
        text = "" if payload is None else str(payload);
        return {
            "ok": False,
            "error": str(e),
            "lines": [x for x in text.split("\n")],
        };
    }
}
