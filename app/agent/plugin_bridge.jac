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
        md_transformers: list = [];

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
        result = entry["handler"](args, {"ui": FakeUi(notifications)});
        return {
            "ok": True,
            "result": "" if result is None else str(result),
            "notifications": notifications,
        };
    } except Exception as e {
        return {
            "ok": False,
            "error": str(e),
            "notifications": notifications,
        };
    }
}


"""Minimal UI surface handed to fake-host handlers; collects notifications."""
obj FakeUi {
    has notifications: list[str];

    def notify(message: str, level: str = "info") {
        self.notifications.append(str(message));
    }

    def set_status(owner: str, text: str) {
        # Native-UI surface — accepted on the wire, not rendered.
    }
}


"""Fire a lifecycle hook. Returns the per-listener results list from the
hook_done payload: [{ok, extension_id, result|error, notifications?}].
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
        return raw if isinstance(raw, list) else [];
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
            out = handler(data, {"ui": FakeUi(notifications)});
            results.append({
                "ok": True,
                "result": "" if out is None else str(out),
                "notifications": notifications,
            });
        } except Exception as e {
            results.append({"ok": False, "error": str(e), "notifications": notifications});
        }
    }
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
        return out;
    }
    # Fake host path.
    h = bridge.host;
    if h is None or not h.alive {
        return {"ok": True, "markdown": md};
    }
    for t in h.md_transformers {
        try {
            out = t["fn"](md, mctx);
            if isinstance(out, str) {
                md = out;
            }
        } except Exception {
            # Keep prior output, continue the chain.
        }
    }
    return {"ok": True, "markdown": md};
}
