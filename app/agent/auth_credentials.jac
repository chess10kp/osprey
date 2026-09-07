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
