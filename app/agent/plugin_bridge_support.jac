"""Plugin bridge path and envelope support."""

import os;import shutil;import from .protocol { Envelope, make_envelope }

def _path_abspath(p: str) -> str {
    fn: any = os.path.abspath;
    return str(fn(p));
}


def _path_dirname(p: str) -> str {
    fn: any = os.path.dirname;
    return str(fn(p));
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



def envelope_to_dict(env: Envelope) -> dict[str, any] {
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


def envelope_from_dict(data: dict[str, any]) -> Envelope {
    raw_payload: any = data.get("payload", {});
    payload: dict[str, any] = {};
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

