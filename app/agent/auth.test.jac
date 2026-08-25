"""Auth store + flow state machine tests for agent/auth.jac.

Covers: load/save round trips in the legacy auth.json format (both
credential types plus unknown extra keys), a hand-written fixture built
from the TS AuthStorageData shape, missing/corrupt file tolerance,
restricted file permissions, expiry math (live/expired/boundary/garbage),
stored_api_key routing, redaction never leaking secrets, provider/model
entry validation + filtering + labels, the full login flow transition
table including cancel mid-flow and pending-step detection, the network
seam envelopes, and path resolution. Uses Python tempfile dirs with fake
auth.json files (cleaned up per test) -- NEVER touches the real
~/.pi/agent/auth.json, pi/auth.json, or ~/.jackal/auth.json.
"""

import os;
import json;
import stat;
import tempfile;
import shutil;


def _make_tmp() -> str {
    return tempfile.mkdtemp(prefix="jackal-auth-test-");
}


def _cleanup(tmp: str) {
    shutil.rmtree(tmp, ignore_errors=True);
}


def _auth_path(tmp: str) -> str {
    return os.path.join(tmp, "auth.json");
}


def _read_raw(path: str) -> any {
    fh = open(path, "r");
    try {
        return json.load(fh);
    } finally {
        fh.close();
    }
}


def _dirname(p: str) -> str {
    fn: any = os.path.dirname;
    return str(fn(p));
}


def _write_text(path: str, text: str) {
    os.makedirs(_dirname(path), exist_ok=True);
    fh = open(path, "w");
    try {
        fh.write(text);
    } finally {
        fh.close();
    }
}


def _api_cred(key: str) -> dict {
    return {"type": "api_key", "key": key};
}


def _oauth_cred(access: str, refresh: str, expires: int) -> dict {
    return {"type": "oauth", "access": access, "refresh": refresh,
            "expires": expires};
}


# ============================== store ==============================


test "load/save round trip preserves both credential types and unknown keys" {
    tmp = _make_tmp();
    try {
        data = {
            "anthropic": _api_cred("sk-ant-live-1234"),
            "openai-codex": dict(_oauth_cred("acc-token", "ref-token", 9999999999999),
                                 **{"account_id": "acct-42", "lastRefresh": "2026-01-01"}),
            "totally-unknown-provider": {"type": "weird", "stuff": [1, 2]},
        };
        assert save_auth_file(_auth_path(tmp), data);

        loaded = load_auth_file(_auth_path(tmp));
        assert loaded == data;
        assert loaded["anthropic"]["key"] == "sk-ant-live-1234";
        assert loaded["openai-codex"]["account_id"] == "acct-42";
        assert loaded["openai-codex"]["lastRefresh"] == "2026-01-01";

        # Save of the loaded copy is byte-equivalent content again.
        assert save_auth_file(_auth_path(tmp), loaded);
        reloaded = load_auth_file(_auth_path(tmp));
        assert reloaded == data;
    } finally {
        _cleanup(tmp);
    }
}


test "hand-written legacy-format fixture parses exactly like the TS shape" {
    tmp = _make_tmp();
    try {
        # Built from src/auth/auth.ts: Record<string, ApiKeyCredential |
        # OAuthCredential> where OAuthCredential = {type:"oauth"} &
        # OAuthCredentials {refresh, access, expires(ms), ...unknown}.
        fixture = '''{
  "anthropic": {
    "type": "api_key",
    "key": "sk-ant-api03-fixture"
  },
  "openai-codex": {
    "type": "oauth",
    "refresh": "rt_fixture",
    "access": "at_fixture",
    "expires": 1893456000000,
    "account_id": "org-fixture"
  }
}''';
        _write_text(_auth_path(tmp), fixture);
        data = load_auth_file(_auth_path(tmp));
        assert set(data.keys()) == {"anthropic", "openai-codex"};
        cred = credential_get(data, "openai-codex");
        assert cred is not None;
        assert cred["access"] == "at_fixture";
        assert cred["refresh"] == "rt_fixture";
        assert cred["expires"] == 1893456000000;
        assert cred["account_id"] == "org-fixture";
        assert not is_expired(cred);
        assert stored_api_key(data, "anthropic") == "sk-ant-api03-fixture";
    } finally {
        _cleanup(tmp);
    }
}


test "missing file and non-object roots default to empty store" {
    tmp = _make_tmp();
    try {
        assert load_auth_file(_auth_path(tmp)) == {};
        _write_text(_auth_path(tmp), "[1, 2, 3]");
        assert load_auth_file(_auth_path(tmp)) == {};
        _write_text(_auth_path(tmp), '"just a string"');
        assert load_auth_file(_auth_path(tmp)) == {};
        _write_text(_auth_path(tmp), "");
        assert load_auth_file(_auth_path(tmp)) == {};

        # Missing dir for save is created; nested too.
        deep = os.path.join(tmp, "a", "b", "auth.json");
        assert save_auth_file(deep, {});
        assert load_auth_file(deep) == {};
    } finally {
        _cleanup(tmp);
    }
}


test "corrupt JSON tolerance: garbage files yield {} without raising" {
    tmp = _make_tmp();
    try {
        for junk in ["{not json", "}{" , "{\"a\":}", "\x00\xff binary-ish"] {
            _write_text(_auth_path(tmp), junk);
            assert load_auth_file(_auth_path(tmp)) == {};
        }
    } finally {
        _cleanup(tmp);
    }
}


test "save writes 0600 perms, indent=2, trailing newline" {
    tmp = _make_tmp();
    try {
        path = _auth_path(tmp);
        assert save_auth_file(path, {"p": _api_cred("k")});
        mode = stat.S_IMODE(os.stat(path).st_mode);
        assert mode == 0o600;
        raw = "";
        fh = open(path, "r");
        try {
            raw = fh.read();
        } finally {
            fh.close();
        }
        assert raw.endswith("\n");
        assert "\n  \"p\": {" in raw;  # indent=2 pretty print
        # Parent dir created with restricted mode as well.
        dmode = stat.S_IMODE(os.stat(tmp).st_mode);
        assert dmode & 0o077 == 0;
    } finally {
        _cleanup(tmp);
    }
}


test "credential set/remove are immutable snapshots and persist to disk" {
    tmp = _make_tmp();
    try {
        path = _auth_path(tmp);
        original = {"a": _api_cred("ka")};
        updated = credential_set(original, "b", _oauth_cred("t", "r", 5_000_000_000_000));
        assert original == {"a": _api_cred("ka")};  # input untouched
        assert has_credential(updated, "b");
        assert not has_credential(original, "b");

        trimmed = credential_remove(updated, "a");
        assert "a" not in trimmed and "b" in trimmed;
        assert "a" in updated;  # remove did not mutate either

        assert save_auth_file(path, trimmed);
        disk = load_auth_file(path);
        assert set(disk.keys()) == {"b"};
        # Removing an absent provider is a no-op snapshot.
        assert credential_remove(trimmed, "nope") == trimmed;

        # Malformed entries are skipped by the validated accessors...
        broken = {"bad": {"type": "api_key"}, "ok": _api_cred("fine")};
        assert credential_get(broken, "bad") is None;
        assert credential_get(broken, "ok") is not None;
        assert not has_credential(broken, "bad");
    } finally {
        _cleanup(tmp);
    }
}


test "validate_credential rejects junk but preserves unknown extra keys" {
    tmp_data_list: list = [
        None, 42, "str", [], {}, {"type": "mystery"},
        {"type": "api_key"}, {"type": "api_key", "key": ""},
        {"type": "oauth", "access": "a"},
        {"type": "oauth", "access": "a", "refresh": "r"},
        {"type": "oauth", "access": "a", "refresh": "r", "expires": "soon"},
    ];
    for item in tmp_data_list {
        assert validate_credential(item) is None;
    }
    api = validate_credential({"type": "api_key", "key": "kk", "note": "extra"});
    assert api == {"type": "api_key", "key": "kk", "note": "extra"};
    oa = validate_credential({"type": "oauth", "access": "a", "refresh": "r",
                              "expires": 123, "project_id": "pj"});
    assert oa["project_id"] == "pj" and oa["expires"] == 123;
}


# ============================== expiry ==============================


test "expiry math: live, expired, boundary-inclusive, garbage expires" {
    now = 1_000_000_000_000;
    assert not is_expired(_oauth_cred("a", "r", now + 1), at_ms=now);
    assert is_expired(_oauth_cred("a", "r", now - 1), at_ms=now);
    # Boundary: exactly equal counts as expired (Date.now() >= expires).
    assert is_expired(_oauth_cred("a", "r", now), at_ms=now);
    # Garbage / missing expires fail safe toward expired.
    assert is_expired({"type": "oauth", "access": "a", "refresh": "r"}, at_ms=now);
    assert is_expired({"type": "oauth", "access": "a", "refresh": "r",
                       "expires": None}, at_ms=now);
    assert is_expired(None, at_ms=now);
    assert is_expired({"type": "junk"}, at_ms=now);
    # API keys never expire.
    assert not is_expired(_api_cred("k"), at_ms=now - 100_000_000);
}


test "stored_api_key routes api keys live oauth and expired-oauth-to-seam" {
    now = 1_000_000_000_000;
    data = {
        "plain": _api_cred("the-key"),
        "live": _oauth_cred("live-access", "r", now + 60_000),
        "dead": _oauth_cred("stale-access", "r", now - 60_000),
        "broken": {"type": "oauth", "access": "x", "refresh": "y"},
    };
    assert stored_api_key(data, "plain", at_ms=now) == "the-key";
    assert stored_api_key(data, "live", at_ms=now) == "live-access";
    # Expired or malformed OAuth must NOT hand out tokens here: refreshing
    # is the runtime loop's job via the network seam.
    assert stored_api_key(data, "dead", at_ms=now) is None;
    assert stored_api_key(data, "broken", at_ms=now) is None;
    assert stored_api_key(data, "unknown-provider", at_ms=now) is None;
}


test "get_auth_status precedence: runtime > stored > env > unconfigured" {
    stored = {"a": _api_cred("k")};
    assert get_auth_status("a", stored, runtime_keys=["a"]) == {
        "configured": True, "source": "stored", "label": "runtime override",
    };
    assert get_auth_status("a", stored) == {"configured": True, "source": "stored"};
    assert get_auth_status("envonly", stored, env_api_key="ek") == {
        "configured": True, "source": "environment", "label": "env",
    };
    assert get_auth_status("none", stored) == {"configured": False};
}


test "resolve_auth_path honours explicit dir then env then home fallback" {
    tmp = _make_tmp();
    old = os.environ.get("JACKAL_AGENT_DIR");
    try {
        assert resolve_auth_path(tmp) == os.path.join(tmp, "auth.json");
        os.environ["JACKAL_AGENT_DIR"] = tmp;
        assert resolve_auth_path() == _auth_path(tmp);
        # Explicit arg still wins over the env var.
        other = os.path.join(tmp, "other");
        assert resolve_auth_path(other) == os.path.join(other, "auth.json");
    } finally {
        if old is None {
            os.environ.pop("JACKAL_AGENT_DIR", None);
        } else {
            os.environ["JACKAL_AGENT_DIR"] = old;
        }
        _cleanup(tmp);
    }
}


# ============================== redaction ==============================


test "redaction never leaks secrets in any display form" {
    secret = "sk-super-secret-value-ZX9Q";
    cred = {"type": "oauth", "access": secret, "refresh": "rt-short",
            "expires": 123, "account_id": "acct-ok-id"};
    masked = redact_credential(cred);
    assert masked is not None;
    blob = json.dumps(masked);
    assert secret not in blob;
    assert "rt-short" not in blob;
    # Type stays visible; non-secret scalars pass through.
    assert masked["type"] == "oauth";
    assert masked["expires"] == 123;
    # Only the tail is shown for long secrets.
    assert masked["access"].endswith(secret[-4:]);
    assert "*" * 8 in str(masked["access"]);
    assert redact_credential(None) is None;
    assert redact_credential([]) is None;

    # Short secrets render fully masked (nothing recoverable).
    short = redact_secret("abc");
    assert short == "*" * 8;
    assert redact_secret("") == "(unset)";
    assert redact_secret(None) == "(unset)";
    long_masked = redact_secret(secret);
    assert long_masked.endswith("ZX9Q");
    assert secret not in long_masked;
}


# ============================== flow machine ==============================


def _provider(pid: str, auth_type: str, configured: bool = False) -> dict {
    return {"id": pid, "displayName": pid.title(), "authType": auth_type,
            "configured": configured, "modelCount": 2};
}


test "picker transitions validate entries and drop invalid ones" {
    st = initial_auth_flow_state();
    assert st["step"]["kind"] == "idle";
    st = transition_auth_flow(st, "open_provider_picker", {"providers": [
        _provider("anthropic", "oauth", True),
        {"id": "", "displayName": "broken", "authType": "oauth"},
        {"id": "ok", "displayName": "ok", "authType": "telepathy"},
        "not-even-a-dict",
        _provider("mistral", "api_key"),
    ]});
    assert st["step"]["kind"] == "provider_picker";
    assert st["step"]["query"] == "";
    ids = [str(e["id"]) for e in st["step"]["providers"]];
    assert ids == ["anthropic", "mistral"];
    assert not step_is_pending(st);

    st = transition_auth_flow(st, "open_model_picker", {"models": [
        {"provider": "anthropic", "modelId": "claude-5", "displayName": "Claude 5"},
        {"provider": "", "modelId": "x", "displayName": "bad"},
    ]});
    assert st["step"]["kind"] == "model_picker";
    picked_models: any = st["step"]["models"];
    assert isinstance(picked_models, list);
    assert len(picked_models) == 1;
    assert st["step"]["providerFilter"] is None;
}


test "login happy path: picker to logging_in to browser_auth to logged_in" {
    st = initial_auth_flow_state();
    st = transition_auth_flow(st, "open_provider_picker", {"providers": [_provider("anthropic", "oauth")]});
    st = transition_auth_flow(st, "set_logging_in",
                              {"providerId": "anthropic", "status": "starting OAuth"});
    assert st["step"]["kind"] == "logging_in";
    assert st["step"]["status"] == "starting OAuth";

    st = transition_auth_flow(st, "set_browser_auth",
                              {"providerId": "anthropic", "url": "https://auth.example/x"});
    assert st["step"]["kind"] == "browser_auth";
    assert st["step"]["url"] == "https://auth.example/x";
    assert "instructions" not in st["step"];

    st = transition_auth_flow(st, "set_browser_auth",
                              {"providerId": "anthropic", "url": "u", "instructions": "paste code"});
    assert st["step"]["instructions"] == "paste code";

    st = transition_auth_flow(st, "set_logged_in",
                              {"providerId": "anthropic", "nextStep": "model_picker"});
    assert st["step"]["kind"] == "logged_in";
    assert st["step"]["nextStep"] == "model_picker";
    assert not step_is_pending(st);
}


test "user-input steps flag pending until resolved" {
    st = initial_auth_flow_state();
    st = transition_auth_flow(st, "set_prompt",
                              {"providerId": "p", "message": "API key?", "placeholder": "sk-..."});
    assert st["step"]["kind"] == "prompt";
    assert step_is_pending(st);
    st = transition_auth_flow(st, "set_manual_code", {"providerId": "p"});
    assert st["step"]["kind"] == "manual_code" and step_is_pending(st);
    st = transition_auth_flow(st, "set_select",
                              {"providerId": "p", "message": "pick org",
                               "options": [{"id": "o1", "label": "Org One"}]});
    assert st["step"]["kind"] == "select" and step_is_pending(st);
    st = transition_auth_flow(st, "set_api_key_input", {"providerId": "p"});
    assert st["step"]["kind"] == "api_key_input" and step_is_pending(st);
    st = transition_auth_flow(st, "set_idle");
    assert st["step"]["kind"] == "idle" and not step_is_pending(st);
}


test "cancel mid-flow returns to idle from any pending state" {
    for (action, payload) in [
        ("set_prompt", {"providerId": "p", "message": "m"}),
        ("set_manual_code", {"providerId": "p"}),
        ("set_select", {"providerId": "p", "message": "m", "options": []}),
        ("set_api_key_input", {"providerId": "p"}),
        ("set_browser_auth", {"providerId": "p", "url": "u"}),
        ("set_logging_in", {"providerId": "p", "status": "s"}),
    ] {
        st = initial_auth_flow_state();
        st = transition_auth_flow(st, action, payload);
        assert st["step"]["kind"] != "idle";
        cancelled = transition_auth_flow(st, "cancel");
        assert cancelled["step"]["kind"] == "idle";
        assert not step_is_pending(cancelled);
        # Original state object was not mutated by the cancel.
        assert st["step"]["kind"] != "idle";
    }
    # reset lands on the same idle shape as a fresh machine.
    st = transition_auth_flow(initial_auth_flow_state(), "set_error", {"message": "boom"});
    assert transition_auth_flow(st, "reset") == initial_auth_flow_state();
}


test "query updates only affect picker steps and stay immutable" {
    st = transition_auth_flow(initial_auth_flow_state(),
                              "open_provider_picker",
                              {"providers": [_provider("a", "oauth")]});
    before = json.dumps(st);
    qd = transition_auth_flow(st, "update_query", {"query": "an"});
    assert qd["step"]["query"] == "an";
    assert json.dumps(st) == before;  # no mutation

    ms = transition_auth_flow(qd, "open_model_picker", {"models": [
        {"provider": "a", "modelId": "m1", "displayName": "M1"}]});
    ms = transition_auth_flow(ms, "update_query", {"query": "m1"});
    assert ms["step"]["query"] == "m1";
    ms = transition_auth_flow(ms, "update_provider_filter", {"providerFilter": "a"});
    assert ms["step"]["providerFilter"] == "a";

    # Non-picker steps ignore query/filter updates entirely.
    err = transition_auth_flow(initial_auth_flow_state(), "set_error", {"message": "x"});
    same = transition_auth_flow(err, "update_query", {"query": "zzz"});
    assert same == err and same["step"]["kind"] == "error";
    assert transition_auth_flow(err, "update_provider_filter",
                                {"providerFilter": "a"}) == err;
}


test "error steps carry message and optional provider id; unknown actions noop" {
    st = transition_auth_flow(initial_auth_flow_state(), "set_error", {"message": "denied"});
    assert st["step"] == {"kind": "error", "message": "denied"};
    st = transition_auth_flow(st, "set_error", {"message": "denied", "providerId": "p"});
    assert st["step"]["providerId"] == "p";

    base = transition_auth_flow(initial_auth_flow_state(), "set_logging_in",
                                {"providerId": "p", "status": "s"});
    weird = transition_auth_flow(base, "teleport_to_mars", {"anything": True});
    assert weird == base;  # unknown action returns unchanged copy
}


test "filters and labels match the picker rendering contract" {
    providers = [
        _provider("anthropic", "oauth", True),
        _provider("openai", "api_key"),
        _provider("github-copilot", "oauth"),
    ];
    hits = filter_providers_by_query(providers, "copilot");
    assert len(hits) == 1 and hits[0]["id"] == "github-copilot";
    # Case-insensitive across id and displayName.
    assert len(filter_providers_by_query(providers, "ANTHROPIC")) == 1;
    assert len(filter_providers_by_query(providers, "OpenAI")) == 1;
    assert filter_providers_by_query(providers, "") == providers;

    models = [
        {"provider": "anthropic", "modelId": "claude-opus", "displayName": "Opus"},
        {"provider": "openai", "modelId": "gpt-mini", "displayName": "Mini"},
        {"provider": "anthropic", "modelId": "claude-haiku", "displayName": "Haiku"},
    ];
    assert len(filter_models_by_query(models, "claude")) == 2;
    assert len(filter_models_by_query(models, "", "anthropic")) == 2;
    assert len(filter_models_by_query(models, "mini", "anthropic")) == 0;
    assert len(filter_models_by_query(models, "OPUS", "")) == 1;

    assert format_provider_label(providers[0]) == "[✓] Anthropic (OAuth, 2 models)";
    assert format_provider_label(providers[1]) == "[ ] Openai (API Key, 2 models)";
    assert format_model_label(models[0]) == "Opus (anthropic/claude-opus)";
    assert format_model_label({"modelId": "bare"}) == "bare";
    assert format_model_label({}) == "unknown";
}


test "login_kind classifies which providers need oauth vs prompt vs nothing" {
    assert needs_oauth("oauth");
    assert not needs_oauth("api_key");
    assert not needs_oauth("env");
    assert login_kind("api_key") == "api_key";
    assert login_kind("env") == "env";
    assert login_kind("telepathy") == "";
    assert not needs_oauth(None);
}


# ============================== network seam ==============================


test "network seams return explicit not-supported envelopes" {
    for result in [
        oauth_refresh_credentials("anthropic", _oauth_cred("a", "r", 1)),
        oauth_start_login("anthropic"),
    ] {
        assert result["ok"] is False;
        assert result["error"] == "network_not_supported";
        assert result["provider"] == "anthropic";
        assert isinstance(result["detail"], str) and result["detail"];
    }
}
