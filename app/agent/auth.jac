"""Provider credentials store + login flow state machine for the native
harness (ported from src/auth/auth.ts, lib/jac/auth/_auth_io_toolchain.py,
lib/jac/auth/_auth_flow_toolchain.py, and src/auth/auth-flow.ts).

On-disk shape (auth.json, byte-compatible with the legacy pi-ai runtime):
a single JSON object mapping provider id -> credential, where a credential
is one of:
- API key: {"type": "api_key", "key": "<secret>"}
- OAuth:   {"type": "oauth", "refresh": "<token>", "access": "<token>",
            "expires": <epoch milliseconds>, ...unknown extras}
pi-ai OAuthCredentials allows arbitrary extra keys ([key: string]:
unknown), so unknown keys inside a credential AND unknown top-level
providers are preserved verbatim on load and round-trip unchanged through
save. Files are written indent=2 + trailing newline, chmod 0600, parent
dirs created 0700 -- matching the TS saveAuthFile exactly.

Expiry math mirrors pi-ai's OAuth refresh check: ``Date.now() >= creds.expires``
means expired (boundary inclusive); a missing/non-numeric ``expires`` is
treated as expired so callers always route through the refresh seam.

NETWORK SEAM (not portable -- filled by the runtime loop):
oauth_start_login() and oauth_refresh_credentials() would perform browser /
HTTP I/O against provider OAuth endpoints. That stays with the LLM runtime
loop; here they return the explicit not-supported value
{"ok": False, "error": "network_not_supported", ...} documented below.
Callers treat that value as "delegate to the host runtime, persist whatever
credentials come back with credential_set".

Not ported: pi-ai provider/model catalogs (getProviders/getModels),
pi-ai getEnvApiKey lookup (callers pass the env key in), and the reactive
AuthFlowStore machinery (listeners, AbortController, promise resolvers) --
only the pure transition table is ported; pending user-input steps are
detected via step_is_pending so the UI layer can wire resolvers itself.
"""

import os;
import json;
import stat;
import time;
import copy;

glob AUTH_FILE_NAME: str = "auth.json";

glob DEFAULT_AGENT_DIR_NAME: str = ".jackal";

glob KNOWN_AUTH_TYPES: list[str] = ["oauth", "api_key", "env"];

glob OAUTH_REQUIRED_KEYS: list[str] = ["refresh", "access"];


# ── Checker shims ───────────────────────────────────────────────────────


"""Checker shims: the Jac type checker cannot bind AnyStr when plain str
values flow into some os.path/stat signatures (abspath/expanduser/chmod),
so route those calls through any-typed aliases."""
def _path_abspath(p: str) -> str {
    fn: any = os.path.abspath;
    return str(fn(p));
}


def _path_expanduser(p: str) -> str {
    fn: any = os.path.expanduser;
    return str(fn(p));
}


def _path_dirname(p: str) -> str {
    fn: any = os.path.dirname;
    return str(fn(p));
}


def _file_chmod(p: str, mode: int) {
    fn: any = os.chmod;
    fn(p, mode);
}


# ── Path resolution ─────────────────────────────────────────────────────


"""Resolve the auth.json path: explicit agent_dir > JACKAL_AGENT_DIR env
> ~/.jackal/. Mirrors the TS resolveAuthPath."""
def resolve_auth_path(agent_dir: str = "") -> str {
    base = agent_dir;
    if not base {
        base = os.environ.get("JACKAL_AGENT_DIR") or "";
    }
    if not base {
        base = os.path.join(_path_expanduser("~"), DEFAULT_AGENT_DIR_NAME);
    }
    return os.path.join(base, AUTH_FILE_NAME);
}


# ── Credential store ────────────────────────────────────────────────────


"""Load and parse auth.json. Missing file, corrupt JSON, or a non-object
root all yield {} (legacy behaviour: auth failures never crash boot)."""
def load_auth_file(path: str) -> dict {
    if not os.path.isfile(path) {
        return {};
    }
    fh = None;
    try {
        fh = open(path, "r");
        raw = json.load(fh);
    } except (OSError, ValueError) {
        return {};
    } finally {
        if fh is not None {
            fh.close();
        }
    }
    if isinstance(raw, dict) {
        return raw;
    }
    return {};
}


"""Save auth data as pretty JSON (indent=2 + trailing newline), creating
parent dirs 0700 and chmod-ing the file 0600. True on success."""
def save_auth_file(path: str, data: dict) -> bool {
    parent = _path_dirname(_path_abspath(path));
    try {
        if not os.path.isdir(parent) {
            os.makedirs(parent, mode=0o700, exist_ok=True);
        }
        fh = open(path, "w");
        json.dump(data, fh, indent=2);
        fh.write("\n");
        fh.close();
        owner_rw: any = stat.S_IRUSR | stat.S_IWUSR;
        _file_chmod(path, owner_rw);
        return True;
    } except OSError {
        return False;
    }
}


"""Validate and normalise one credential record, preserving unknown keys.

Returns a fresh dict on success, None when the record cannot be an auth
credential (wrong container, unknown/missing type, missing required OAuth
fields). Mirrors the ApiKeyCredential | OAuthCredential union."""
def validate_credential(cred: any) -> dict | None {
    if not isinstance(cred, dict) {
        return None;
    }
    ctype = cred.get("type");
    if ctype == "api_key" {
        key = cred.get("key");
        if not isinstance(key, str) or not key {
            return None;
        }
        out: dict = {"type": "api_key", "key": key};
    } elif ctype == "oauth" {
        for field in OAUTH_REQUIRED_KEYS {
            if not isinstance(cred.get(field), str) or not cred[field] {
                return None;
            }
        }
        expires = cred.get("expires");
        if not isinstance(expires, (int, float)) or isinstance(expires, bool) {
            return None;
        }
        out = {"type": "oauth", "access": cred["access"],
               "refresh": cred["refresh"], "expires": expires};
    } else {
        return None;
    }
    # Preserve every unknown extra key verbatim (byte-compat requirement).
    for (k, v) in cred.items() {
        if k not in out {
            out[k] = v;
        }
    }
    return out;
}


"""Stored credential for one provider, validated; None when absent or
malformed (malformed entries are skipped rather than trusted)."""
def credential_get(data: dict, provider: str) -> dict | None {
    if provider not in data {
        return None;
    }
    return validate_credential(data[provider]);
}


"""Return a NEW data dict with `provider` bound to `cred`; the input dict
is never mutated (store snapshots stay immutable like the TS spreads)."""
def credential_set(data: dict, provider: str, cred: dict) -> dict {
    nxt = dict(data);
    nxt[provider] = cred;
    return nxt;
}


"""Return a NEW data dict without `provider` (no-op when absent)."""
def credential_remove(data: dict, provider: str) -> dict {
    nxt: dict = {};
    for (k, v) in data.items() {
        if k != provider {
            nxt[k] = v;
        }
    }
    return nxt;
}


"""True when a well-formed credential exists for the provider."""
def has_credential(data: dict, provider: str) -> bool {
    return credential_get(data, provider) is not None;
}


# ── Expiry math ─────────────────────────────────────────────────────────


"""Epoch milliseconds (pi-ai stores OAuth expiry in ms, not seconds)."""
def now_ms() -> int {
    return int(time.time() * 1000);
}


"""Whether a credential is unusable at `at_ms`.

API keys never expire. OAuth credentials expire when the stored ``expires``
(epoch ms) is <= the clock -- boundary inclusive, matching pi-ai's
``Date.now() >= creds.expires`` refresh trigger -- or when ``expires`` is
missing/garbage (fail safe toward refresh). Non-oauth/non-api_key records
count as expired so they never satisfy live-key lookups."""
def is_expired(cred: any, at_ms: int = -1) -> bool {
    if not isinstance(cred, dict) {
        return True;
    }
    if cred.get("type") == "api_key" and isinstance(cred.get("key"), str) and cred["key"] {
        return False;
    }
    if cred.get("type") != "oauth" {
        return True;
    }
    expires = cred.get("expires");
    if not isinstance(expires, (int, float)) or isinstance(expires, bool) {
        return True;
    }
    now = at_ms if at_ms >= 0 else now_ms();
    return now >= expires;
}


"""Best usable secret string for a provider from stored data alone.

api_key -> the key. oauth -> the access token ONLY while unexpired; an
expired token returns None because refresh requires the network seam
(oauth_refresh_credentials) which the runtime loop must fill. Anything
else -> None."""
def stored_api_key(data: dict, provider: str, at_ms: int = -1) -> str | None {
    cred = credential_get(data, provider);
    if cred is None or is_expired(cred, at_ms) {
        return None;
    }
    if cred["type"] == "api_key" {
        return str(cred["key"]);
    }
    return str(cred.get("access", ""));
}


"""Auth status summary mirroring the TS getAuthStatus: runtime overrides
win, then stored credentials, then a caller-supplied env key."""
def get_auth_status(
    provider: str,
    stored_providers: dict,
    runtime_keys: list | None = None,
    env_api_key: str = "",
) -> dict {
    runtimes = runtime_keys if runtime_keys is not None else [];
    if provider in runtimes {
        return {"configured": True, "source": "stored", "label": "runtime override"};
    }
    if provider in stored_providers {
        return {"configured": True, "source": "stored"};
    }
    if env_api_key {
        return {"configured": True, "source": "environment", "label": "env"};
    }
    return {"configured": False};
}


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


# ── Login flow state machine (from _auth_flow_toolchain.py) ─────────────


"""Initial flow state: the idle step."""
def initial_auth_flow_state() -> dict {
    return {"step": {"kind": "idle"}};
}


"""Steps that block on user input (prompt/manual_code/select/api_key_input).
The UI layer attaches promise resolvers to these; cancel mid-flow means
abandoning such a step and returning to idle."""
def step_is_pending(state: dict) -> bool {
    kind = state.get("step", {}).get("kind", "");
    return kind in ["prompt", "manual_code", "select", "api_key_input"];
}


"""Pure transition table for the login flow. Actions:
open_provider_picker, open_model_picker, set_logging_in, set_browser_auth,
set_prompt, set_manual_code, set_select, set_api_key_input, set_logged_in,
set_error, set_idle, update_query, update_provider_filter, cancel, reset.
Unknown actions return an unchanged copy. Never mutates current_state."""
def transition_auth_flow(current_state: dict, action: str, payload: dict | None = None) -> dict {
    p = payload if payload is not None else {};
    step = current_state.get("step", {});

    if action == "open_provider_picker" {
        incoming: list = p.get("providers", []);
        valid: list = [];
        for item in incoming {
            v = validate_provider_entry(item);
            if v is not None {
                valid.append(v);
            }
        }
        return {"step": {"kind": "provider_picker", "providers": valid, "query": ""}};
    }

    if action == "open_model_picker" {
        incoming: list = p.get("models", []);
        valid: list = [];
        for item in incoming {
            v = validate_model_entry(item);
            if v is not None {
                valid.append(v);
            }
        }
        return {"step": {"kind": "model_picker", "models": valid,
                         "providerFilter": None, "query": ""}};
    }

    if action == "set_logging_in" {
        return {"step": {"kind": "logging_in",
                         "providerId": p.get("providerId", ""),
                         "status": p.get("status", "")}};
    }

    if action == "set_browser_auth" {
        result_step: dict = {
            "kind": "browser_auth",
            "providerId": p.get("providerId", ""),
            "url": p.get("url", ""),
        };
        if p.get("instructions") {
            result_step["instructions"] = p["instructions"];
        }
        return {"step": result_step};
    }

    if action == "set_prompt" {
        return {"step": {"kind": "prompt",
                         "providerId": p.get("providerId", ""),
                         "message": p.get("message", ""),
                         "placeholder": p.get("placeholder", "")}};
    }

    if action == "set_manual_code" {
        return {"step": {"kind": "manual_code",
                         "providerId": p.get("providerId", "")}};
    }

    if action == "set_select" {
        return {"step": {"kind": "select",
                         "providerId": p.get("providerId", ""),
                         "message": p.get("message", ""),
                         "options": p.get("options", [])}};
    }

    if action == "set_api_key_input" {
        return {"step": {"kind": "api_key_input",
                         "providerId": p.get("providerId", "")}};
    }

    if action == "set_logged_in" {
        return {"step": {"kind": "logged_in",
                         "providerId": p.get("providerId", ""),
                         "nextStep": p.get("nextStep", "done")}};
    }

    if action == "set_error" {
        result_step: dict = {"kind": "error", "message": p.get("message", "")};
        if p.get("providerId") {
            result_step["providerId"] = p["providerId"];
        }
        return {"step": result_step};
    }

    if action == "set_idle" {
        return {"step": {"kind": "idle"}};
    }

    if action == "update_query" {
        query = p.get("query", "");
        kind = step.get("kind");
        if kind == "provider_picker" or kind == "model_picker" {
            new_step = copy.deepcopy(step);
            new_step["query"] = query;
            return {"step": new_step};
        }
        return copy.deepcopy(current_state);
    }

    if action == "update_provider_filter" {
        provider_filter = p.get("providerFilter");
        if step.get("kind") == "model_picker" {
            new_step = copy.deepcopy(step);
            new_step["providerFilter"] = provider_filter;
            return {"step": new_step};
        }
        return copy.deepcopy(current_state);
    }

    if action == "cancel" {
        return {"step": {"kind": "idle"}};
    }

    if action == "reset" {
        return initial_auth_flow_state();
    }

    return copy.deepcopy(current_state);
}


# ── Network seam (filled by the runtime loop, NOT here) ────────────────
#
# Both functions below would perform HTTP/browser I/O against provider
# OAuth endpoints. That belongs to the LLM runtime loop, which owns fetch,
# local callback servers, and browser launch. They therefore return the
# explicit not-supported envelope documented on each signature; callers
# must treat ok=False + error="network_not_supported" as "ask the host
# runtime to perform this step, then persist returned credentials via
# credential_set/save_auth_file".


"""SEAM: exchange an OAuth refresh token for fresh credentials.

Would POST the refresh grant to the provider's token endpoint. Returns
{"ok": False, "error": "network_not_supported", "provider": <id>,
"detail": "..."}; the runtime loop fills this by performing the refresh
and handing back a validated credential dict to store."""
def oauth_refresh_credentials(provider_id: str, credentials: dict) -> dict {
    return {
        "ok": False,
        "error": "network_not_supported",
        "provider": provider_id,
        "detail": (
            "OAuth token refresh needs HTTP against the provider token "
            "endpoint; the runtime loop must perform it and persist the "
            "resulting credential."
        ),
    };
}


"""SEAM: start an interactive OAuth login for a provider.

Would open the authorize URL (and possibly a local callback server).
Returns {"ok": False, "error": "network_not_supported", "provider": <id>,
"detail": "..."}; the runtime loop drives the browser dance and hands back
credentials to store."""
def oauth_start_login(provider_id: str) -> dict {
    return {
        "ok": False,
        "error": "network_not_supported",
        "provider": provider_id,
        "detail": (
            "Interactive OAuth login needs a browser + callback server; "
            "the runtime loop must drive it and persist the resulting "
            "credential."
        ),
    };
}
