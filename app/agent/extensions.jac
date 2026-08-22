"""Native control plane for Pi/JS extension declarations (D21 / PLUGIN-HOST-PLAN).

Startup reads lightweight decls only — no Node module evaluation on the Jac
render path. Session owns warm of a parallel Node sidecar when any
runtime=node extension is declared.
"""

import json;
import os;
import time;

obj ExtensionDecl {
    has id: str = "",
        path: str = "",
        runtime: str = "node",
        activation: str = "sidecar",
        requires: list = [];
}


obj ExtensionStatus {
    has phase: str = "idle",
        loaded: int = 0,
        total: int = 0,
        ready: bool = True,
        detail: str = "",
        label: str = "",
        t_interactive_s: float = 0.0,
        t_ext_ready_s: float = 0.0,
        compat_tier: str = "T0";
}


"""Parse one extension dict into ExtensionDecl (missing fields → defaults)."""
def decl_from_dict(raw: dict) -> ExtensionDecl {
    req: list = [];
    raw_req: any = raw.get("requires", []);
    if isinstance(raw_req, list) {
        req = [str(x) for x in raw_req];
    }
    runtime = str(raw.get("runtime", "node") or "node");
    activation = str(raw.get("activation", "") or "");
    if not activation {
        if runtime == "native" {
            activation = "native";
        } else {
            activation = "sidecar";
        }
    }
    return ExtensionDecl(
        id=str(raw.get("id", "")),
        path=str(raw.get("path", "")),
        runtime=runtime,
        activation=activation,
        requires=req,
    );
}


"""Normalize a JSON document into a list of ExtensionDecl."""
def decls_from_json(data: any) -> list[ExtensionDecl] {
    rows: list = [];
    if isinstance(data, list) {
        rows = data;
    } elif isinstance(data, dict) {
        maybe: any = data.get("extensions", []);
        if isinstance(maybe, list) {
            rows = maybe;
        }
    }
    out: list[ExtensionDecl] = [];
    for row in rows {
        if isinstance(row, dict) {
            d = decl_from_dict(row);
            if d.id and d.path {
                out.append(d);
            }
        }
    }
    return out;
}


"""Walk up from cwd for .jackal/extensions.json or .jackal with extensions key."""
def load_extension_decls(cwd: str = "") -> list[ExtensionDecl] {
    start = cwd if cwd else os.getcwd();
    cur = os.path.abspath(start);
    while True {
        ext_path = os.path.join(cur, ".jackal", "extensions.json");
        if os.path.isfile(ext_path) {
            try {
                with open(ext_path, "r") as fh {
                    return decls_from_json(json.load(fh));
                }
            } except (OSError, ValueError) {
            }
        }
        jackal_path = os.path.join(cur, ".jackal");
        if os.path.isfile(jackal_path) {
            try {
                with open(jackal_path, "r") as fh {
                    data = json.load(fh);
                }
                if isinstance(data, dict) and "extensions" in data {
                    return decls_from_json(data);
                }
            } except (OSError, ValueError) {
            }
        }
        parent = os.path.dirname(cur);
        if parent == cur {
            break;
        }
        cur = parent;
    }
    return [];
}


"""Node decls that should warm on the sidecar (sidecar/default; not lazy/native)."""
def node_sidecar_decls(decls: list[ExtensionDecl]) -> list[ExtensionDecl] {
    out: list[ExtensionDecl] = [];
    for d in decls {
        if d.runtime != "node" {
            continue;
        }
        if d.activation == "lazy" {
            continue;
        }
        out.append(d);
    }
    return out;
}


"""Format status label: extensions: loading n/m | ready | degraded | idle."""
def extensions_label(status: ExtensionStatus) -> str {
    if status.total <= 0 {
        return "extensions: idle";
    }
    if status.phase == "ready" and status.ready {
        return f"extensions: ready {status.loaded}/{status.total}";
    }
    if status.phase == "degraded" {
        return f"extensions: degraded {status.loaded}/{status.total}";
    }
    if status.phase == "dead" {
        return f"extensions: dead {status.loaded}/{status.total}";
    }
    return f"extensions: loading {status.loaded}/{status.total}";
}


"""Resolve extension path relative to base cwd."""
def resolve_decl_path(decl: ExtensionDecl, base_cwd: str) -> str {
    p = decl.path;
    if os.path.isabs(p) {
        return p;
    }
    return os.path.abspath(os.path.join(base_cwd, p));
}
