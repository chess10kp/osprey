"""Plugin bridge — Node sidecar transport + fake-host dispatch seams.

Speaks the same Envelope types as agent.protocol. Session may warm Node in
parallel with the first frame; undeclared installs never start Node.
Async stdout reader + correlation map multiplex replies (P3).

The in-process FAKE host (FakePluginHost, register_fake_*, ...) lives in
agent/fake_host.jac — unit-test-only, re-exported here for compatibility.
Host caps/compat tier are always DERIVED from the received host_hello
envelope (apply_hello), never from hand-copied constants.
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
import from .interactions { new_ui_queue, UiInteractionQueue }
import from .fake_host {
    FakePluginHost,
    FakeUi,
    apply_hello,
    create_fake_host,
    ensure_host,
    touch_bridge,
}


obj PluginBridge {
    has session_id: str = "",
        host: FakePluginHost | None = None,
        host_kind: str = "",
        proc: any = None,
        node_bin: str = "node",
        host_mjs: str = "",
        next_corr: int = 1,
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
        ui_q: any = None,
        interactive_ui: bool = False,
        traffic_messages: list = [],
        traffic_entries: list = [],
        session_name: str = "",
        shortcuts: dict = {},
        labels: dict = {},
        pending_model: str = "",
        pending_thinking_level: str = "";

    """Dispatch a js tool (fake or Node) — used by registry.invoke."""
    def invoke_js_tool(name: str, args: dict) -> str {
        return invoke_tool(self, name, args);
    }
}


# ── Checker shims ───────────────────────────────────────────────────────


"""Checker shims: the Jac type checker cannot bind AnyStr when plain str
values flow into os.path abspath/dirname, so route those calls through
any-typed aliases (same pattern as auth.jac / checkpoints.jac)."""
def _path_abspath(p: str) -> str {
    fn: any = os.path.abspath;
    return str(fn(p));
}


def _path_dirname(p: str) -> str {
    fn: any = os.path.dirname;
    return str(fn(p));
}


def create_bridge(session_id: str) -> PluginBridge {
    return PluginBridge(session_id=session_id);
}


"""Resolve plugin_host/host.mjs from cwd (app/ or repo root)."""
def resolve_host_mjs(explicit: str = "") -> str {
    if explicit {
        if os.path.isfile(explicit) {
            return _path_abspath(explicit);
        }
        raise FileNotFoundError(f"host.mjs not found: {explicit}");
    }
    cwd = os.getcwd();
    candidates = [
        os.path.join(cwd, "plugin_host", "host.mjs"),
        os.path.join(cwd, "app", "plugin_host", "host.mjs"),
    ];
    here = _path_dirname(_path_abspath(str(__file__)));
    candidates.append(os.path.join(here, "..", "plugin_host", "host.mjs"));
    for c in candidates {
        if os.path.isfile(c) {
            return _path_abspath(c);
        }
    }
    raise FileNotFoundError("plugin_host/host.mjs not found (run from app/ or repo root)");
}


"""Resolve fixtures/stub_echo.mjs beside the host."""
def resolve_stub_echo(explicit: str = "") -> str {
    if explicit {
        if os.path.isfile(explicit) {
            return _path_abspath(explicit);
        }
        raise FileNotFoundError(f"stub_echo not found: {explicit}");
    }
    host = resolve_host_mjs();
    path = os.path.join(_path_dirname(host), "fixtures", "stub_echo.mjs");
    if not os.path.isfile(path) {
        raise FileNotFoundError(f"stub_echo fixture missing: {path}");
    }
    return path;
}
def resolve_pi_greet(explicit: str = "") -> str {
    if explicit {
        if os.path.isfile(explicit) {
            return _path_abspath(explicit);
        }
        raise FileNotFoundError(f"pi_greet not found: {explicit}");
    }
    host = resolve_host_mjs();
    path = os.path.join(_path_dirname(host), "fixtures", "pi_greet.mjs");
    if not os.path.isfile(path) {
        raise FileNotFoundError(f"pi_greet fixture missing: {path}");
    }
    return path;
}


def resolve_pi_ctx_probe(explicit: str = "") -> str {
    if explicit {
        if os.path.isfile(explicit) {
            return _path_abspath(explicit);
        }
        raise FileNotFoundError(f"pi_ctx_probe not found: {explicit}");
    }
    host = resolve_host_mjs();
    path = os.path.join(_path_dirname(host), "fixtures", "pi_ctx_probe.mjs");
    if not os.path.isfile(path) {
        raise FileNotFoundError(f"pi_ctx_probe fixture missing: {path}");
    }
    return path;
}

def resolve_stub_commands(explicit: str = "") -> str {
    if explicit {
        if os.path.isfile(explicit) {
            return _path_abspath(explicit);
        }
        raise FileNotFoundError(f"stub_commands not found: {explicit}");
    }
    host = resolve_host_mjs();
    path = os.path.join(_path_dirname(host), "fixtures", "stub_commands.mjs");
    if not os.path.isfile(path) {
        raise FileNotFoundError(f"stub_commands fixture missing: {path}");
    }
    return path;
}

def resolve_pi_gated(explicit: str = "") -> str {
    if explicit {
        if os.path.isfile(explicit) {
            return _path_abspath(explicit);
        }
        raise FileNotFoundError(f"pi_gated not found: {explicit}");
    }
    host = resolve_host_mjs();
    path = os.path.join(_path_dirname(host), "fixtures", "pi_gated.mjs");
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
        host_dir = _path_dirname(host);
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
}


"""Route an inbound envelope to a pending waiter; always keep a copy in inbox.

Kind-aware: a waiter registered with expect_kind only completes for that kind;
mismatched envelopes stay inbox-only so interleaved traffic (tool_update vs
tool_result, future ui_request children) cannot wake or consume the wrong
waiter."""
def _dispatch_inbound(bridge: PluginBridge, env: Envelope) {
    # P12 interactive-UI traffic routes to the interaction queue, never to
    # parent waiters and never into the unbounded diagnostic inbox.
    if env.kind == "ui_request" {
        _ui_enqueue_from_env(bridge, env);
        return;
    }
    if env.kind == "ui_cancel" {
        q0: any = bridge.ui_q;
        if q0 is not None {
            q0.take(str(env.correlation_id));
        }
        return;
    }
    bridge.inbox.append(env);
    corr = env.correlation_id;
    pending = bridge.pending;
    if corr and corr in pending {
        waiter: any = pending[corr];
        expect: any = waiter.get("expect", "");
        if expect and str(expect) != env.kind {
            return;
        }
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
def _prepare_corr(
    bridge: PluginBridge, correlation_id: str, expect_kind: str = ""
) {
    _ensure_io(bridge);
    if correlation_id and correlation_id not in bridge.pending {
        # expect_kind: only an envelope of this kind may complete the waiter.
        # Guards against sibling traffic (e.g. tool_update sharing the parent
        # correlation with tool_result) waking the wrong waiter.
        bridge.pending[correlation_id] = {
            "event": threading.Event(),
            "env": None,
            "expect": expect_kind,
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
        _prepare_corr(bridge, correlation_id, expect_kind=kind);
        # UI lease (P12): while a correlated ui_request sits open for this
        # parent, the fixed handler budget is PAUSED — bounded by a
        # cumulative 600s lease measured from first grant. User think-time
        # must not kill the command/hook that asked the question.
        while True {
            pending: any = bridge.pending.get(correlation_id);
            if pending is None {
                break;  # dispatcher consumed it without storing env
            }
            if pending.get("env") is not None {
                bridge.pending.pop(correlation_id, None);
                got: any = pending["env"];
                return got as Envelope;
            }
            lease_start: any = pending.get("ui_lease_start");
            if lease_start is not None {
                # Lease active: short polls only (honors the 600s cap and
                # keeps wakeups bounded to the interaction window).
                if time.monotonic() >= float(lease_start) + 600.0 {
                    bridge.pending.pop(correlation_id, None);
                    raise TimeoutError(f"timed out waiting for {kind}");
                }
                pending["event"].wait(timeout=0.05);
                continue;
            }
            remaining = max(0.01, deadline - time.monotonic());
            ok = pending["event"].wait(timeout=remaining);
            if ok {
                continue;  # dispatcher stored env; re-check at loop top
            }
            # Budget exhausted — grant a UI lease iff a correlated request
            # is still open (user think-time pauses the handler budget).
            q: any = bridge.ui_q;
            has_pending_ui = False;
            if q is not None {
                has_pending_ui = (q as UiInteractionQueue).has_open(correlation_id);
            }
            if has_pending_ui {
                pending["ui_lease_start"] = time.monotonic();
                continue;
            }
            bridge.pending.pop(correlation_id, None);
            raise TimeoutError(f"timed out waiting for {kind}");
        }
        raise TimeoutError(f"timed out waiting for {kind}");
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
    apply_hello(bridge, hello);
    touch_bridge(bridge);
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
    touch_bridge(bridge);
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


"""Composite capability gate (P12 slice 5): interactive_ui means the Node
host can round-trip AND this frontend installed a UI adapter. Line/JSON
frontends fail loud at ext_load instead of at first ui.select call."""
def ui_cap_satisfied(bridge: PluginBridge, requires: list, has_ui: bool) -> bool {
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
    requires: list = [],
    has_ui: bool = False,
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
    builtins: list[dict] = [];
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
        touch_bridge(bridge);
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
    if corr in h.cancelled {
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
    _prepare_corr(bridge, corr, expect_kind="tool_result");
    req = make_envelope(
        kind="tool_invoke",
        session_id=bridge.session_id,
        tool_id=name,
        correlation_id=corr,
        payload={"name": name, "args": args},
    );
    try {
        _write_node(bridge, req);
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


# ======================= T2-partial: shortcuts =======================

"""Invoke an extension keyboard shortcut by key. Returns the shortcut_result
payload dict: {ok, notifications?, ui_events?, error?}; failures (including
Node silence/timeout) come back as {ok: False, error: ...}, never raised."""
def invoke_shortcut(bridge: PluginBridge, key: str, timeout: float = 10.0) -> dict {
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
def list_shortcuts(bridge: PluginBridge | None) -> dict {
    if bridge is None {
        return {};
    }
    return dict(bridge.shortcuts);
}


"""Labels set by loaded extensions via pi.setLabel (id -> meta dict)."""
def list_labels(bridge: PluginBridge | None) -> dict {
    if bridge is None {
        return {};
    }
    return dict(bridge.labels);
}


"""Drain pending extension setModel/setThinkingLevel requests.

Returns {"model": str, "thinking_level": str} and clears both pendings so
each request applies exactly once. Empty strings mean no request."""
def drain_model_requests(bridge: PluginBridge | None) -> dict {
    out: dict = {"model": "", "thinking_level": ""};
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
        _prepare_corr(bridge, corr, expect_kind="hook_done");
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
        touch_bridge(bridge);
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
            # tool_result middleware: partial patches apply to the working
            # copy so later handlers see the latest result.
            if isinstance(out, dict) {
                if isinstance(out.get("content"), str) {
                    working["content"] = out["content"];
                }
                if isinstance(out.get("isError"), bool) {
                    working["isError"] = out["isError"];
                }
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


"""tool_result gate: fires the Pi `tool_result` hook over a finished result.

Pi middleware semantics: each handler sees the latest content (hosts apply
{content, isError} patches between handlers) and may return partial patches.
Returns {ok, result, is_error} — never raises; on any failure the original
result passes through untouched."""
def tool_result_gate(
    bridge: PluginBridge | None,
    name: str,
    args: dict,
    result: str,
) -> dict {
    out: dict = {"ok": True, "result": result, "is_error": False};
    if bridge is None {
        return out;
    }
    data = {
        "toolName": str(name),
        "toolCallId": "",
        "input": args,
        "content": result,
        "isError": False,
    };
    try {
        fired = fire_hook_data(bridge, "tool_result", data);
        results = fired.get("results", []);
        final = fired.get("data", {});
    } except Exception {
        return out;
    }
    any_ok = False;
    for v in _ok_verdicts(results) {
        if isinstance(v.get("content"), str) or isinstance(v.get("isError"), bool) {
            any_ok = True;
        }
    }
    if not any_ok {
        return out;
    }
    content: any = final.get("content") if isinstance(final, dict) else None;
    is_err: any = final.get("isError") if isinstance(final, dict) else None;
    out["ok"] = True;
    if isinstance(content, str) {
        out["result"] = content;
    }
    out["is_error"] = bool(is_err) if isinstance(is_err, bool) else False;
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


"""Fire a lifecycle hook. Returns the per-listener results list from the
hook_done payload: [{ok, extension_id, result|error, verdict?,
notifications?, ui_events?}] where verdict carries the handler's raw object
return when it returned a dict ({block}, {action}, {systemPrompt}, ...).
Returns [] when no host exists (hooks are best-effort, never fatal)."""
def fire_hook(bridge: PluginBridge, event: str, data: dict, timeout: float = 10.0) -> list {
    if bridge.host_kind == "node" and _node_alive(bridge) {
        corr = _alloc_corr(bridge);
        _prepare_corr(bridge, corr, expect_kind="hook_done");
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
        touch_bridge(bridge);
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


# ===================== cheap lifecycle events (name-pinned helpers) =====================

"""Fire the Pi `user_bash` hook when the agent runs a shell command.

Payload mirrors Pi: {command, result?}. Session-side call site (one-liner
when wired): relay_tool_hooks in agent/session.jac — fire where tool ==
"run_command". Best-effort: no host or transport failure returns []."""
def fire_user_bash(
    bridge: PluginBridge | None, command: str, result: str = ""
) -> list {
    if bridge is None {
        return [];
    }
    data: dict = {"command": str(command)};
    if result {
        data["result"] = str(result)[:2000];
    }
    try {
        return fire_hook(bridge, "user_bash", data);
    } except Exception {
        return [];
    }
}


"""Fire the Pi `project_trust` hook when a project directory is first
trusted. Payload: {path}. Best-effort: no host or transport failure
returns []."""
def fire_project_trust(bridge: PluginBridge | None, path: str) -> list {
    if bridge is None {
        return [];
    }
    try {
        return fire_hook(bridge, "project_trust", {"path": str(path)});
    } except Exception {
        return [];
    }
}


# ======================= T2-partial: markdown transformers =======================

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
        _prepare_corr(bridge, corr, expect_kind="md_transformed");
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
        touch_bridge(bridge);
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
        _prepare_corr(bridge, corr, expect_kind="rendered");
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


# ============================ P10: provider seam ============================

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
        _prepare_corr(bridge, corr, expect_kind="rendered");
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
        touch_bridge(bridge);
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
    renderer: any = table.get(str(type));
    if renderer is None or not isinstance(renderer, dict) {
        return none_out;
    }
    try {
        out: any = renderer["fn"](payload);
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


# ==================== P12: interactive ui round-trip ====================

def _ui_queue(bridge: PluginBridge) -> UiInteractionQueue {
    if bridge.ui_q is None {
        bridge.ui_q = new_ui_queue();
    }
    return bridge.ui_q as UiInteractionQueue;
}


def _ui_enqueue_from_env(bridge: PluginBridge, env: Envelope) {
    p = env.payload if env.payload is not None else {};
    req = {
        "corr": str(env.correlation_id or ""),
        "parent_corr": str(p.get("parent_correlation_id", "")),
        "parent_kind": str(p.get("parent_kind", "")),
        "extension_id": str(p.get("extension_id", "")),
        "method": str(p.get("method", "")),
        "title": str(p.get("title", "")),
        "message": str(p.get("message", "")),
        "options": p.get("options", []) if isinstance(p.get("options"), list) else [],
        "placeholder": str(p.get("placeholder", "")),
        "created": time.monotonic(),
        "timeout_ms": float(p.get("timeout_ms", 30000.0)),
    };
    q = _ui_queue(bridge);
    res = q.enqueue(req);
    if not res[0] {
        # Invalid request: tell Node immediately so its Promise settles.
        _ui_send_response(bridge, str(env.correlation_id), "cancelled", None, str(res[1]));
    }
}


def _ui_send_response(
    bridge: PluginBridge, corr: str, status: str, value: any, reason: str = ""
) -> bool {
    payload: dict = {"status": status};
    if value is not None {
        payload["value"] = value;
    }
    if reason {
        payload["reason"] = reason;
    }
    if bridge.host_kind == "node" and _node_alive(bridge) {
        try {
            _write_node(bridge, make_envelope(
                kind="ui_response",
                session_id=bridge.session_id,
                correlation_id=corr,
                payload=payload,
            ));
            return True;
        } except Exception {
            return False;
        }
    }
    return True;  # fake-host path: nothing to write
}


"""Poll the oldest live UI request for the TUI mainloop. Reaped-expired
requests are answered cancelled automatically. Returns a payload dict for
the modal controller or None:
{corr, parent_corr, parent_kind, extension_id, method, title, message,
options, placeholder}."""
def poll_ui_request(bridge: PluginBridge) -> dict | None {
    if bridge is None or bridge.ui_q is None {
        return None;
    }
    q = bridge.ui_q as UiInteractionQueue;
    polled: list = q.poll(time.monotonic());
    live: any = polled[0];
    expired: list = polled[1];
    for r in expired {
        rr: any = r;
        _ui_send_response(bridge, str(rr.corr), "cancelled", None, "timeout");
    }
    if live is None {
        return None;
    }
    return {
        "corr": live.corr,
        "parent_corr": live.parent_corr,
        "parent_kind": live.parent_kind,
        "extension_id": live.extension_id,
        "method": live.method,
        "title": live.title,
        "message": live.message,
        "options": list(live.options),
        "placeholder": live.placeholder,
    };
}


"""Answer one pending request. select/input pass strings, confirm passes
bool. Unknown/expired corr is ignored (idempotent)."""
def respond_ui(bridge: PluginBridge, corr: str, value: any) -> bool {
    if bridge is None or bridge.ui_q is None {
        return False;
    }
    r: any = (bridge.ui_q as UiInteractionQueue).take(str(corr));
    if r is None {
        return False;
    }
    return _ui_send_response(bridge, str(r.corr), "ok", value);
}


"""Cancel one pending request by child correlation."""
def cancel_ui(bridge: PluginBridge, corr: str, reason: str = "cancelled") -> bool {
    if bridge is None or bridge.ui_q is None {
        return False;
    }
    r: any = (bridge.ui_q as UiInteractionQueue).take(str(corr));
    if r is None {
        return False;
    }
    return _ui_send_response(bridge, str(r.corr), "cancelled", None, reason);
}


"""Cancel every open request (turn abort / dispose). Returns count."""
def cancel_all_ui(bridge: PluginBridge, reason: str = "cancelled") -> int {
    if bridge is None or bridge.ui_q is None {
        return 0;
    }
    q = bridge.ui_q as UiInteractionQueue;
    n = 0;
    # Drain via take() so queue and wire stay consistent.
    while True {
        recs: list = [];
        polled2: list = q.poll(time.monotonic());
        live: any = polled2[0];
        expired: list = polled2[1];
        for r in expired + ([live] if live is not None else []) {
            recs.append(r);
        }
        if len(recs) == 0 {
            break;
        }
        for r in recs {
            rr2: any = r;
            _ui_send_response(bridge, str(rr2.corr), "cancelled", None, reason);
            n += 1;
        }
        # poll() is a peek: only expired records are detached automatically.
        # Detach the live record explicitly or this loop spins until its
        # deadline lapses.
        if live is not None {
            q.take(str(live.corr));
        }
    }
    return n;
}
