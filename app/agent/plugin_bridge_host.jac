"""Plugin bridge host lifecycle and health management."""

import os;
import subprocess;
import time;

import from .protocol { Envelope, make_envelope }
import from .fake_host { ensure_host, touch_bridge }
import from .plugin_bridge_support { resolve_host_mjs, resolve_node_bin }
def _emit_host_status(bridge: any, phase: str, detail: str = "") {
    bridge.status_phase = phase;
    bridge.inbox.append(
        make_envelope(
            kind="host_status",
            session_id=bridge.session_id,
            payload={"phase": phase, "detail": detail},
        )
    );
}


def _node_alive(bridge: any) -> bool {
    if bridge.host_kind != "node" or bridge.proc is None {
        return False;
    }
    return bridge.proc.poll() is None;
}
import from .plugin_bridge_io {
    _ensure_io,
    _start_reader,
    _stop_reader,
    _read_node_until,
    _write_node,
}

"""Inspect host health. Dead Node → degraded status envelope; returns phase."""
def host_status(bridge: any) -> str {
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
    bridge: any, idle_timeout_s: float = -1.0, now: float = -1.0
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

def ensure_node_host(
    bridge: any,
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
def maybe_restart_host(bridge: any, timeout: float = 5.0) -> str {
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


def dispose_bridge(bridge: any) {
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
