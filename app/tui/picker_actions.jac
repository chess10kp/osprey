"""Picker data sources and authentication actions."""
import os;
import from tui.state { LiveShell }
import from tui.core { _push_turn, _meter }
import from tui.picker_base { _open_picker, _close_picker }
import from agent.llm { PROVIDER_ROUTES, credential_error }
import from agent.session {
    model_preferences, get_model, set_model, get_history, restore_history, provider_for,
}
import from agent.auth {
    load_auth_file, save_auth_file, resolve_auth_path, credential_set,
    stored_api_key, get_auth_status, transition_auth_flow,
    initial_auth_flow_state, format_provider_label, oauth_start_login,
}
import from agent.tasks { load_tasks, format_tasks_list, task_counts }
import from agent.sessions { list_sessions }
import from ui.transcript { apply_transcript_revision }
import from agent.checkpoints {
    create_checkpoint, list_checkpoints, load_checkpoint,
    restore_checkpoint_files, format_checkpoint_overlay_row,
}
import from agent.skills { load_jackal_skills }
import from ui.screen { shell_open_approval }
import from tui.context { _skills_picker_entries }

def _model_picker_entries() -> dict {
    rows: list[str] = [];
    ids: list[str] = [];
    prefs: dict = {};
    try {
        prefs = dict(model_preferences());
    } except Exception {
        prefs = {};
    }
    for prov in PROVIDER_ROUTES {
        route = PROVIDER_ROUTES[prov];
        meta: any = route if isinstance(route, dict) else {};
        desc = str(meta.get("description", "") or "");
        header = "── " + str(prov);
        if desc {
            header += " — " + desc;
        }
        rows.append(header + " ──");
        ids.append("__header__");
        for m in (meta.get("models", []) or []) {
            mname = str(m);
            rows.append("  " + mname);
            ids.append(mname);
        }
        last = str(prefs.get(str(prov), "") or "");
        if last {
            rows.append("  " + last + "  · last");
            ids.append(last);
        }
    }
    return {"rows": rows, "ids": ids};
}


"""Provider rows for /login. Native routes use API-key auth today; routes
that advertise an OAuth authType are retained so their explicit network seam
can report a useful error instead of pretending to log in."""
def _login_provider_entries() -> dict {
    stored = load_auth_file(resolve_auth_path());
    rows: list[str] = [];
    ids: list[str] = [];
    for prov in PROVIDER_ROUTES {
        provider_id = str(prov);
        route: any = PROVIDER_ROUTES[prov];
        meta: dict = route if isinstance(route, dict) else {};
        key_env = str(meta.get("key_env", "") or "");
        auth_type = str(meta.get("authType", "api_key" if key_env else "env"));
        if auth_type == "env" {
            continue;
        }
        status = get_auth_status(
            provider_id,
            stored,
            env_api_key=os.environ.get(key_env, "") if key_env else "",
        );
        item = {
            "id": provider_id,
            "displayName": provider_id,
            "authType": auth_type,
            "configured": bool(status.get("configured", False)),
            "modelCount": len(meta.get("models", []) or []),
        };
        rows.append(format_provider_label(item));
        ids.append(provider_id);
    }
    return {"rows": rows, "ids": ids, "stored": stored};
}


"""Apply a stored native API key only when the process does not already
have an explicit environment override. This keeps provider routing intact
across launches without changing persisted credentials or leaking them into
the transcript."""
def _hydrate_auth_environment() {
    stored = load_auth_file(resolve_auth_path());
    for prov in PROVIDER_ROUTES {
        provider_id = str(prov);
        route: any = PROVIDER_ROUTES[prov];
        meta: dict = route if isinstance(route, dict) else {};
        key_env = str(meta.get("key_env", "") or "");
        if not key_env or os.environ.get(key_env, "") {
            continue;
        }
        key = stored_api_key(stored, provider_id);
        if key {
            os.environ[key_env] = key;
        }
    }
}


def _login_error(app: LiveShell, message: str) {
    app.auth_flow = transition_auth_flow(
        app.auth_flow,
        "set_error",
        {"message": message, "providerId": app.picker.get("providerId", "") if app.picker is not None else ""},
    );
    if app.picker is not None {
        _close_picker(app);
    }
    _push_turn(app, "tool", "login error: " + message);
    app.status_hint = "login failed · /login to retry";
    app.dirty = True;
}


def _cancel_login(app: LiveShell) {
    app.auth_flow = transition_auth_flow(app.auth_flow, "cancel");
    if app.picker is not None {
        _close_picker(app);
    }
    _push_turn(app, "tool", "login cancelled");
    app.status_hint = "login cancelled · enter · ↑↓ history · esc quit";
    app.dirty = True;
}


def _start_login_provider(app: LiveShell, provider_id: str) {
    entries = _login_provider_entries();
    stored: dict = entries.get("stored", {});
    found: dict | None = None;
    for item in PROVIDER_ROUTES {
        if str(item) == provider_id {
            route: any = PROVIDER_ROUTES[item];
            found = route if isinstance(route, dict) else {};
            break;
        }
    }
    if found is None {
        _login_error(app, "unknown provider: " + provider_id);
        return;
    }
    key_env = str(found.get("key_env", "") or "");
    auth_type = str(found.get("authType", "api_key" if key_env else "env"));
    app.auth_data = stored;
    app.auth_flow = transition_auth_flow(
        app.auth_flow,
        "set_logging_in",
        {"providerId": provider_id, "status": "starting"},
    );
    if auth_type == "oauth" {
        result = oauth_start_login(provider_id);
        detail = str(result.get("detail", "") or "") if isinstance(result, dict) else "";
        _login_error(
            app,
            "OAuth login is unavailable in the native runtime"
            + (": " + detail if detail else ""),
        );
        return;
    }
    if not key_env {
        _login_error(app, "provider " + provider_id + " has no interactive login");
        return;
    }
    if app.picker is None {
        _login_error(app, "login overlay unavailable");
        return;
    }
    app.picker["mode"] = "input";
    app.picker["providerId"] = provider_id;
    app.picker["authType"] = auth_type;
    app.picker["keyEnv"] = key_env;
    app.picker["draft"] = "";
    app.auth_flow = transition_auth_flow(
        app.auth_flow,
        "set_api_key_input",
        {"providerId": provider_id},
    );
    app.status_hint = "paste API key · enter save · esc cancel";
    app.dirty = True;
}

def _complete_api_key_login(app: LiveShell, provider_id: str, key: str) {
    if not key {
        _login_error(app, "API key cannot be empty");
        return;
    }
    next_data = credential_set(app.auth_data, provider_id, {"type": "api_key", "key": key});
    path = resolve_auth_path();
    if not save_auth_file(path, next_data) {
        _login_error(app, "could not save credentials to " + path);
        return;
    }
    app.auth_data = next_data;
    route: any = PROVIDER_ROUTES.get(provider_id, {});
    key_env = str(route.get("key_env", "") or "") if isinstance(route, dict) else "";
    if key_env {
        os.environ[key_env] = key;
    }
    app.auth_flow = transition_auth_flow(
        app.auth_flow,
        "set_logged_in",
        {"providerId": provider_id, "nextStep": "done"},
    );
    if app.picker is not None {
        _close_picker(app);
    }
    _push_turn(app, "tool", "logged in to " + provider_id + "; credentials saved to " + path);
    app.status_hint = "login complete · enter · ↑↓ history · esc quit";
    app.dirty = True;
}
"""Model picker: provider-grouped rows from PROVIDER_ROUTES (headers,
advertised models, per-provider "· last" entries), the active model
injected when missing, plus a free-text fallback row; cursor starts on
the active model."""
def _open_model_picker(app: LiveShell) -> str {
    entries = _model_picker_entries();
    choices: list[str] = list(entries["rows"]);
    pick_ids: list[str] = list(entries["ids"]);
    active_model = get_model();
    if active_model not in pick_ids {
        choices.insert(0, active_model + "  · current");
        pick_ids.insert(0, active_model);
    }
    sel = 0;
    i = 0;
    for c in pick_ids {
        if c == active_model {
            sel = i;
            break;
        }
        i += 1;
    }
    opened = _open_picker(app, "MODEL", choices, pick_ids, extra_last_input=True);
    if not opened {
        return "picker unavailable (overlay busy)";
    }
    p: any = app.picker;
    if p is not None {
        p["selected"] = sel;
    }
    return "";
}
"""Open /login's provider picker. An optional provider argument skips the
picker while retaining the same state machine and input overlay."""
def _open_login_picker(app: LiveShell, provider_arg: str = "") -> str {
    entries = _login_provider_entries();
    rows: list[str] = list(entries.get("rows", []));
    ids: list[str] = list(entries.get("ids", []));
    if provider_arg {
        if provider_arg not in ids {
            return "unknown login provider: " + provider_arg;
        }
        app.auth_flow = initial_auth_flow_state();
        app.picker = {
            "title": "LOGIN",
            "options": [],
            "ids": [],
            "selected": 0,
            "mode": "select",
            "draft": "",
            "multi": False,
            "toggled": [],
            "filter": "",
            "prev_hint": app.status_hint,
            "providerId": provider_arg,
        };
        shell_open_approval(app.session, app.shell);
        app.auth_data = entries.get("stored", {});
        _start_login_provider(app, provider_arg);
        return "";
    }
    if not rows {
        return "no interactive providers available";
    }
    if not _open_picker(app, "LOGIN", rows, ids) {
        return "login unavailable (overlay busy)";
    }
    app.auth_data = entries.get("stored", {});
    app.auth_flow = transition_auth_flow(
        initial_auth_flow_state(),
        "open_provider_picker",
        {"providers": [
            {
                "id": ids[i],
                "displayName": ids[i],
                "authType": "api_key",
                "configured": False,
                "modelCount": 0,
            }
            for i in range(len(ids))
        ]},
    );
    app.status_hint = "↑↓ provider · enter choose · esc cancel";
    app.dirty = True;
    return "";

}


"""Resume-picker rows from list_sessions(cwd): label "id  name", payload id."""
def _open_resume_picker(app: LiveShell) -> str {
    rows = list_sessions(os.getcwd());
    if not rows {
        return "no saved sessions";
    }
    labels: list[str] = [];
    ids: list[str] = [];
    for row in rows[:20] {
        sid = str(row.get("id", ""));
        sname = str(row.get("name", ""));
        labels.append(sid[:18] + "  " + sname[:38]);
        ids.append(sid);
    }
    opened = _open_picker(app, "RESUME SESSION", labels, ids);
    if not opened {
        return "picker unavailable (overlay busy)";
    }
    return "";
}


"""TASKS picker rows: a completion-meter summary line, then the rendered
board from format_tasks_list (counts header, divider rule, one row per
task). Row ids: "__header__" for non-selectable lines, the task index as
a string otherwise. Pure over cwd — replicated in tui/overlays.test.jac
(tui/shell.jac cannot be imported headless; keep in sync with the replica)."""
def _task_picker_entries(cwd: str) -> dict {
    tasks = load_tasks(cwd);
    if not tasks {
        return {"rows": ["No tasks yet."], "ids": ["__header__"]};
    }
    counts = task_counts(tasks);
    total: int = int(counts["pending"]) + int(counts["in_progress"]) + int(counts["completed"]);
    ratio: float = float(counts["completed"]) / float(total) if total else 0.0;
    rows: list[str] = [
        str(total) + " tasks  " + _meter(ratio, 14) + "  "
        + str(counts["completed"]) + "/" + str(total) + " done"
    ];
    ids: list[str] = ["__header__"];
    idx = 0;
    for ln in format_tasks_list(tasks).split("\n") {
        rows.append(ln);
        # First two board lines are the counts header and divider rule;
        # everything after maps back onto its task index for enter.
        if idx >= 2 {
            ids.append(str(idx - 2));
        } else {
            ids.append("__header__");
        }
        idx += 1;
    }
    return {"rows": rows, "ids": ids};
}


"""CHECKPOINTS picker rows via list_checkpoints (newest first), one
format_checkpoint_overlay_row line per checkpoint; ids are names. Pure
over cwd — replicated in tui/overlays.test.jac (keep in sync)."""
def _checkpoint_picker_entries(cwd: str) -> dict {
    items = list_checkpoints(cwd);
    rows: list[str] = [];
    ids: list[str] = [];
    for item in items[:20] {
        rows.append(format_checkpoint_overlay_row(item));
        ids.append(str(item.get("name", "")));
    }
    return {"rows": rows, "ids": ids};
}
"""Open the SKILLS catalog overlay; enter inserts `/skill:name ` into the
draft (submitting it inlines the skill body via expand_skill_command)."""
def _open_skills_picker(app: LiveShell) -> str {
    skills: list = [];
    try {
        catalog: dict = load_jackal_skills();
        skills = list(catalog.get("skills", []));
    } except Exception as e {
        return "ERROR: failed to load skills: " + str(e)[:80];
    }
    entries = _skills_picker_entries(skills);
    ids: list = list(entries["ids"]);
    selectable = False;
    for rid in ids {
        if str(rid) != "__header__" {
            selectable = True;
            break;
        }
    }
    if not selectable {
        return str(entries["rows"][0]) if entries["rows"] else "no skills found";
    }
    rows: list[str] = list(entries["rows"]);
    opened = _open_picker(app, "SKILLS", rows, ids);
    if not opened {
        return "picker unavailable (overlay busy)";
    }
    return "";
}


"""Open the read-only tasks overlay; enter on a task echoes the full
rendered board into the transcript."""
def _open_tasks_picker(app: LiveShell) -> str {
    entries = _task_picker_entries(os.getcwd());
    opened = _open_picker(app, "TASKS", entries["rows"], entries["ids"]);
    if not opened {
        return "picker unavailable (overlay busy)";
    }
    return "";
}


"""Open the checkpoints overlay for browse/restore."""
def _open_checkpoints_picker(app: LiveShell) -> str {
    entries = _checkpoint_picker_entries(os.getcwd());
    if not entries["rows"] {
        return "no checkpoints yet (/checkpoint NAME to create one)";
    }
    opened = _open_picker(app, "CHECKPOINTS", entries["rows"], entries["ids"]);
    if not opened {
        return "picker unavailable (overlay busy)";
    }
    return "";
}


"""Snapshot the current conversation plus working-tree changes into a new
named checkpoint (/checkpoint NAME). Provider/model come from the active
session model via provider_for."""
def _create_checkpoint_now(app: LiveShell, name: str) -> str {
    cwd = os.getcwd();
    hist = get_history();
    try {
        active_model = get_model();
        meta = create_checkpoint(cwd, hist, provider_for(active_model), active_model, name=name);
    } except Exception as e {
        return "ERROR: checkpoint failed: " + str(e);
    }
    files_changed: any = meta.get("filesChanged", []);
    n_files = len(files_changed) if isinstance(files_changed, list) else 0;
    app.dirty = True;
    return (
        "checkpoint '" + str(meta.get("name", name)) + "' saved ("
        + str(len(hist)) + " msgs, " + str(n_files) + " files)"
    );
}


"""Restore a checkpoint: write its file snapshots back under cwd, swap the
agent history for the stored conversation, and repaint the transcript.

Known gaps (honest scope of this pass):
- The on-disk session record (.jackal/sessions) is NOT rewritten; it still
  reflects pre-restore turns until the next save/export.
- Transcript rows are rebuilt from raw conversation roles only, so tool-
  call formatting is approximated (same tradeoff as /resume)."""
def _restore_checkpoint(app: LiveShell, name: str) -> str {
    cwd = os.getcwd();
    try {
        payload: any = load_checkpoint(cwd, name);
    } except Exception as e {
        return "ERROR: cannot load checkpoint '" + name + "': " + str(e);
    }
    conv: any = payload.get("conversation") if isinstance(payload, dict) else None;
    msgs: any = conv.get("messages", []) if isinstance(conv, dict) else [];
    if not isinstance(msgs, list) {
        msgs = [];
    }
    note = "";
    files: any = payload.get("fileSnapshots", {}) if isinstance(payload, dict) else {};
    if isinstance(files, dict) and files {
        try {
            restore_checkpoint_files(cwd, files);
            note = ", " + str(len(files)) + " files restored";
        } except Exception as e {
            note = ", FILE RESTORE FAILED: " + str(e).split("\n")[0][:80];
        }
    }
    # Swap agent memory and repaint from the snapshot conversation.
    restore_history(msgs as list);
    app.messages = [];
    app.rev = 0;
    apply_transcript_revision(app.proj, 0, app.messages);
    for m in msgs as list {
        if isinstance(m, dict) and str(m.get("role", "")) != "system" {
            _push_turn(app, str(m.get("role", "")), str(m.get("content", "")));
        }
    }
    app.dirty = True;
    return "checkpoint '" + name + "' restored (" + str(len(msgs)) + " msgs" + note + ")";
}
