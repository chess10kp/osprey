"""Plugin bridge stdio correlation and interactive UI transport."""

import json;
import queue;
import threading;
import time;
import from .protocol { Envelope, make_envelope, is_plugin_kind }
import from .interactions { new_ui_queue, UiInteractionQueue }
import from .plugin_bridge_support { envelope_to_dict, envelope_from_dict }
def _node_alive(bridge: any) -> bool {
    if bridge.host_kind != "node" or bridge.proc is None {
        return False;
    }
    return bridge.proc.poll() is None;
}

def _write_node(bridge: any, env: Envelope) {
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
def _dispatch_inbound(bridge: any, env: Envelope) {
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
def _reader_loop(bridge: any) {
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


def _ensure_io(bridge: any) {
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


def _start_reader(bridge: any) {
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


def _stop_reader(bridge: any) {
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
    bridge: any, correlation_id: str, expect_kind: str = ""
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
    bridge: any,
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


def _read_node(bridge: any, timeout: float = 5.0) -> Envelope {
    return _wait_corr(bridge, "", "", timeout=timeout);
}


"""Read until an envelope with kind matches (or timeout)."""
def _read_node_until(
    bridge: any, kind: str, correlation_id: str = "", timeout: float = 5.0
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
def _ui_queue(bridge: any) -> UiInteractionQueue {
    if bridge.ui_q is None {
        bridge.ui_q = new_ui_queue();
    }
    return bridge.ui_q as UiInteractionQueue;
}


def _ui_enqueue_from_env(bridge: any, env: Envelope) {
    p = env.payload if env.payload is not None else {};
    req: dict[str, any] = {
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
    bridge: any, corr: str, status: str, value: any, reason: str = ""
) -> bool {
    payload: dict[str, any] = {"status": status};
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
