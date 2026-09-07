"""Auth redaction and provider/model picker helpers."""

import from .auth_credentials { KNOWN_AUTH_TYPES }

# ── Redaction / display helpers ─────────────────────────────────────────


"""Mask a secret for display: keep only the last `visible` chars behind a
fixed mask prefix. Empty/unset -> "(unset)". Secrets shorter than
visible+4 render fully masked so length probing stays useless. The output
NEVER contains more of the secret than the tail."""
def redact_secret(secret: any, visible: int = 4) -> str {
    if not isinstance(secret, str) or not secret {
        return "(unset)";
    }
    if len(secret) <= visible + 4 {
        return "*" * 8;
    }
    return "*" * 8 + secret[-visible:];
}


"""Deep-copy a credential with every secret-bearing field redacted.
Unknown extra keys whose values are strings are masked too -- an unknown
key may be a token (e.g. account_id, project_id wrappers)."""
def redact_credential(cred: any) -> dict | None {
    if not isinstance(cred, dict) {
        return None;
    }
    out: dict = {};
    for (k, v) in cred.items() {
        if k == "type" {
            out[k] = v;
        } elif isinstance(v, str) {
            out[k] = redact_secret(v);
        } else {
            out[k] = v;
        }
    }
    return out;
}


# ── Flow item validation + filtering (from _auth_flow_toolchain.py) ────


"""Validate/normalise a provider picker entry; None on failure."""
def validate_provider_entry(item: any) -> dict | None {
    if not isinstance(item, dict) {
        return None;
    }
    pid = item.get("id");
    display = item.get("displayName");
    auth_type = item.get("authType");
    if not isinstance(pid, str) or not pid {
        return None;
    }
    if not isinstance(display, str) or not display {
        return None;
    }
    if auth_type not in KNOWN_AUTH_TYPES {
        return None;
    }
    return {
        "id": pid,
        "displayName": display,
        "authType": auth_type,
        "configured": bool(item.get("configured", False)),
        "modelCount": int(item.get("modelCount", 0)),
    };
}


"""Which login channel a provider item demands: oauth providers need the
browser/network seam, api_key providers need a text prompt, env providers
need nothing. Unknown types degrade to "" (unloginnable)."""
def login_kind(auth_type: any) -> str {
    if auth_type in KNOWN_AUTH_TYPES {
        return str(auth_type);
    }
    return "";
}


"""True when the provider's login must go through the network seam."""
def needs_oauth(auth_type: any) -> bool {
    return login_kind(auth_type) == "oauth";
}


"""Validate/normalise a model picker entry; None on failure."""
def validate_model_entry(item: any) -> dict | None {
    if not isinstance(item, dict) {
        return None;
    }
    provider = item.get("provider");
    model_id = item.get("modelId");
    display = item.get("displayName");
    if not isinstance(provider, str) or not provider {
        return None;
    }
    if not isinstance(model_id, str) or not model_id {
        return None;
    }
    if not isinstance(display, str) or not display {
        return None;
    }
    return {"provider": provider, "modelId": model_id, "displayName": display};
}


"""Case-insensitive substring filter over provider id/displayName."""
def filter_providers_by_query(providers: list, query: str) -> list {
    if not query {
        return list(providers);
    }
    q = query.lower();
    found: list = [];
    for p in providers {
        if q in str(p.get("id", "")).lower() or q in str(p.get("displayName", "")).lower() {
            found.append(p);
        }
    }
    return found;
}


"""Filter models by optional exact provider and case-insensitive query
matched against modelId/displayName/provider."""
def filter_models_by_query(models: list, query: str, provider_filter: str = "") -> list {
    result = models;
    if provider_filter {
        result = [m for m in result if m.get("provider") == provider_filter];
    }
    if query {
        q = query.lower();
        result = [
            m for m in result
            if q in str(m.get("modelId", "")).lower()
            or q in str(m.get("displayName", "")).lower()
            or q in str(m.get("provider", "")).lower()
        ];
    }
    return result;
}


"""Human-readable picker row, e.g. "[✓] Anthropic (OAuth, 12 models)"."""
def format_provider_label(item: dict) -> str {
    name = item.get("displayName", item.get("id", "unknown"));
    auth_type = item.get("authType", "");
    configured = "✓" if item.get("configured") else " ";
    model_count = item.get("modelCount", 0);
    labels = {"oauth": "OAuth", "api_key": "API Key", "env": "Env"};
    auth_label = labels.get(str(auth_type), str(auth_type));
    return "[" + configured + "] " + str(name) + " (" + auth_label + ", " + str(model_count) + " models)";
}


"""Human-readable model row, e.g. "Claude Sonnet (anthropic/claude-5)"."""
def format_model_label(item: dict) -> str {
    display = item.get("displayName", item.get("modelId", "unknown"));
    provider = item.get("provider", "");
    model_id = item.get("modelId", "");
    if provider {
        return str(display) + " (" + str(provider) + "/" + str(model_id) + ")";
    }
    return str(display);
}
