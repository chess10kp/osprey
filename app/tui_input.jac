"""Keyboard, host-event, and per-frame dispatch for LiveShell."""
import os;
import queue;
import from tui_state { LiveShell }
import from tui_core { _push_turn, _scroll_transcript }
import from tui_overlay { _slash_popup_state }
import from tui_picker_base { _close_picker, _multi_filtered }
import from tui_picker_actions { _complete_api_key_login, _start_login_provider, _cancel_login }
import from tui_context {
    _format_mentions, _expand_quoted_context, _insert_into_draft,
}
import from tui_commands {
    _resume_session, _handle_ui_modal_key, _tick_ui_modal,
    _run_slash,
}
import from tui_picker_actions { _restore_checkpoint }
import from tui_runtime {
    _begin_assistant_reply, _finish_stream, _tick_stream,
    _accept_approval, _reject_approval,
}
import from agent.session {
    cancel_active_turn, list_extension_shortcuts, run_extension_shortcut,
    set_mode, set_model,
}
import from agent.modes { cycle_mode, is_read_only_mode }
import from agent.llm { credential_error }
import from agent.tasks { load_tasks, format_tasks_list }
import from ui.screen {
    shell_insert_text, shell_submit, shell_cancel,
}
import from ui.editor { editor_backspace, editor_history_prev, editor_history_next }
import from ui.transcript { set_follow_tail }
import from ui.input { HostEvent, TextEvent, KeyEvent, PasteEvent, coalesce_events }

def _handle_picker_key(app: LiveShell, key: str) {
    p: any = app.picker;
    if p is None {
        return;
    }
    title = str(p.get("title", ""));
    if key == "escape" {
        # Login cancellation is a state-machine transition, not merely an
        # overlay close; the transcript makes the outcome explicit.
        if title == "LOGIN" {
            _cancel_login(app);
            return;
        }
        # Multi-select (EXPLORER): first esc clears an active type-to-filter,
        # second esc closes — the filter is cheap to abandon, the overlay is
        # not.
        if bool(p.get("multi", False)) and str(p.get("filter", "")) {
            p["filter"] = "";
            p["selected"] = 0;
            app.dirty = True;
            return;
        }
        _close_picker(app);
        return;
    }
    if str(p.get("mode", "select")) == "input" {
        draft = str(p.get("draft", ""));
        if key == "enter" {
            if title == "LOGIN" {
                _complete_api_key_login(app, str(p.get("providerId", "")), draft.strip());
            } else {
                name = draft.strip();
                _close_picker(app);
                if name {
                    _push_turn(app, "tool", "model -> " + set_model(name));
                    app.dirty = True;
                }
            }
        } elif key == "backspace" or key == "\x7f" {
            if draft {
                p["draft"] = draft[:-1];
                app.dirty = True;
            }
        } elif len(key) == 1 and key >= " " {
            p["draft"] = draft + key;
            app.dirty = True;
        }
        return;
    }
    options: list = list(p.get("options", []));
    ids: list = list(p.get("ids", []));
    is_multi: bool = bool(p.get("multi", False));
    if is_multi {
        # Type-to-filter: every printable char except space (toggle) narrows
        # the visible rows; backspace edits. j/k are NOT reserved for
        # movement here — arrow keys move — so filenames filter fully.
        filt: str = str(p.get("filter", ""));
        if key == "backspace" or key == "\x7f" {
            if filt {
                p["filter"] = filt[:-1];
                p["selected"] = 0;
                app.dirty = True;
            }
            return;
        }
        if len(key) == 1 and key >= " " and key != " " {
            p["filter"] = filt + key;
            p["selected"] = 0;
            app.dirty = True;
            return;
        }
        vis: tuple[list, list] = _multi_filtered(p);
        options = vis[0];
        ids = vis[1];
    }
    sel = int(p.get("selected", 0));
    if key == " " and is_multi and len(options) > 0 {
        # Multi-select toggle (space arrives as a TextEvent char). Header/
        # divider rows are furniture and never toggle.
        idx = min(sel, len(options) - 1);
        rid = str(ids[idx]) if idx < len(ids) else "";
        if rid and rid != "__header__" {
            toggled: list = list(p.get("toggled", []));
            if rid in toggled {
                toggled.remove(rid);
            } else {
                toggled.append(rid);
            }
            p["toggled"] = toggled;
            app.dirty = True;
        }
        return;
    }
    if (key == "up" or key == "k") and len(options) > 0 {
        p["selected"] = (sel - 1) % len(options);
        app.dirty = True;
    } elif (key == "down" or key == "j") and len(options) > 0 {
        p["selected"] = (sel + 1) % len(options);
        app.dirty = True;
    } elif key == "enter" and len(options) > 0 {
        idx = min(sel, len(options) - 1);
        chosen_id = str(ids[idx]) if idx < len(ids) else "";
        chosen = str(options[idx]);
        if chosen_id == "__type__" {
            p["mode"] = "input";
            p["draft"] = "";
            app.status_hint = "type model id · enter submit · esc cancel";
            app.dirty = True;
            return;
        }
        if title == "LOGIN" {
            _start_login_provider(app, chosen_id);
            return;
        }
        if chosen_id == "__header__" {
            # Header/divider/summary rows are separators, not choices
            # (provider headers in MODEL, board furniture in TASKS).
            app.dirty = True;
            return;
        }
        if bool(p.get("multi", False)) {
            # Multi-select confirm: insert every toggled path as @mentions;
            # with nothing toggled, fall back to the cursor row.
            picks: list = list(p.get("toggled", []));
            if not picks {
                picks = [chosen_id];
            }
            _close_picker(app);
            if title == "EXPLORER" {
                _insert_into_draft(app, _format_mentions(picks));
            }
            app.dirty = True;
            return;
        }
        _close_picker(app);
        if title == "MODEL" {
            mname = chosen_id or chosen;
            cerr = credential_error(mname);
            if cerr {
                # Missing credentials: surface which env var to set instead of
                # switching (same tool-row path as /command results).
                _push_turn(app, "tool", cerr);
            } else {
                _push_turn(app, "tool", "model -> " + mname);
                set_model(mname);
            }
        } elif title == "RESUME SESSION" {
            reply = _resume_session(app, chosen_id);
            if reply {
                _push_turn(app, "tool", reply);
            }
        } elif title == "TASKS" {
            # Read-only overlay: echo the full rendered board into the
            # transcript so long lists survive past the 8-row overlay cap.
            _push_turn(app, "tool", format_tasks_list(load_tasks(os.getcwd())));
        } elif title == "CHECKPOINTS" {
            reply = _restore_checkpoint(app, chosen_id);
            if reply {
                _push_turn(app, "tool", reply);
            }
        } elif title == "SKILLS" {
            # Insert the expansion token; the user appends args and submits,
            # at which point expand_skill_command inlines the skill body.
            _insert_into_draft(app, "/skill:" + chosen_id + " ");
        }
        app.dirty = True;
}
}
"""Prompt history via the shared editor API (ui/editor.jac)."""
def _history_up(app: LiveShell) {
    editor_history_prev(app.shell.prompt);
    app.dirty = True;
}


def _history_down(app: LiveShell) {
    editor_history_next(app.shell.prompt);
    app.dirty = True;
}
"""Drain extension-command worker completions."""
def _tick_cmd(app: LiveShell) {
    if app.cmd_q is None {
        return;
    }
    drained = False;
    while True {
        try {
            item: any = app.cmd_q.get_nowait();
        } except queue.Empty {
            break;
        }
        drained = True;
        name = str(item[1].get("name", "?"));
        out = str(item[1].get("output", ""));
        ok = item[1].get("ok") is True;
        tag = "[ext] /" + name + " -> ";
        for ln in out.split("\n")[:8] {
            _push_turn(app, "tool", tag + ln[:160]);
            tag = "      ";
        }
        if not ok {
            _push_turn(app, "tool", "! [ext] /" + name + " failed");
        }
    }
    if drained {
        app.dirty = True;
    }
}


"""Unified per-frame tick: UI modals + command workers + stream events."""
def _tick_app(app: LiveShell) {
    _tick_cmd(app);
    _tick_ui_modal(app);
    if app.phase == "streaming" {
        _tick_stream(app);
    } elif app.phase == "approval" {
        # Keep the status meter alive while the modal sits.
        app.spin_i += 1;
        if app.spin_i % 4 == 0 {
            app.dirty = True;
        }
    }
}


def _handle_key(app: LiveShell, key: str) {
    if key == "ctrl+c" {
        app.running = False;
        return;
    }
    if key == "ctrl+l" {
        app.dirty = True;
        return;
    }
    # Extension-UI modal first: it shares the overlay node with approvals,
    # so the generic approval branch would otherwise swallow every key.
    if app.ui_modal is not None {
        _handle_ui_modal_key(app, key);
        return;
    }
    if app.picker is not None {
        _handle_picker_key(app, key);
        return;
    }
    if app.shell.approval is not None {
        if key == "a" or key == "y" or key == "enter" {
            _accept_approval(app);
            return;
        }
        if key == "r" or key == "n" {
            _reject_approval(app);
            return;
        }
        if key == "escape" {
            _reject_approval(app);
            return;
        }
        return;
    }
    # Extension keyboard shortcuts (pi.registerShortcut): modifier-combo keys
    # registered by loaded extensions shadow built-in navigation, matching Pi
    # global-binding semantics. ctrl+c / modals / approvals keep precedence.
    scs = list_extension_shortcuts();
    if key in scs {
        meta: dict = scs[key];
        desc = str(meta.get("description", "") or "");
        app.status_hint = "shortcut " + key + (" — " + desc if desc else "");
        reply = run_extension_shortcut(key);
        if reply {
            _push_turn(app, "tool", reply);
        }
        app.dirty = True;
        return;
    }
    # Dev-mode cycle (Shift+Tab): normal -> auto-accept -> yolo -> plan ->
    # ask. The session prompt appendix and approval policy follow this same
    # active mode; blocked tools surface as ERROR tool_result rows.
    if key == "shift+tab" {
        app.mode = cycle_mode(app.mode);
        set_mode(app.mode);
        note: str = "mode → " + app.mode;
        if is_read_only_mode(app.mode) {
            note += "  (write tools blocked)";
        }
        _push_turn(app, "system", note);
        app.status_hint = "mode " + app.mode + " · shift+tab cycles";
        app.dirty = True;
        return;
    }
    # Slash-command autocomplete popup: owns up/down/tab/enter/escape while
    # visible; printable chars and backspace fall through to editing below —
    # the paint-time filter picks up the new draft automatically. j/k stay
    # out on purpose: they must keep inserting text for live filtering.
    popup: list[list[str]] | None = _slash_popup_state(app);
    if popup is not None {
        count = len(popup);
        if key == "up" {
            app.slash_sel = (int(app.slash_sel) - 1 + count) % count;
            app.dirty = True;
            return;
        }
        if key == "down" {
            app.slash_sel = (int(app.slash_sel) + 1) % count;
            app.dirty = True;
            return;
        }
        if key == "tab" or key == "enter" {
            idx = int(app.slash_sel);
            if idx >= count {
                idx = count - 1;
            }
            if idx < 0 {
                idx = 0;
            }
            chosen = str(popup[idx][0]);
            app.shell.prompt.draft = chosen;
            app.shell.prompt.caret = len(chosen);
            app.shell.prompt.history_index = -1;
            # Dismiss at the completed draft: enter must submit on the next
            # press, not re-complete.
            app.slash_dismissed = chosen;
            app.dirty = True;
            return;
        }
        if key == "escape" {
            # First esc closes the popup without touching the draft; the
            # second one (popup now hidden) keeps the existing behavior.
            app.slash_dismissed = app.shell.prompt.draft.strip();
            app.dirty = True;
            return;
        }
    }
    if key == "page_up" {
        # Scrollback works during streaming too: the frozen view just means
        # new chunks append offscreen until tail is re-entered.
        _scroll_transcript(app, -(max(1, app.proj.viewport_height) - 1));
        return;
    }
    if key == "page_down" {
        _scroll_transcript(app, max(1, app.proj.viewport_height) - 1);
        return;
    }
    if key == "home" {
        set_follow_tail(app.proj, False);
        app.proj.view.scroll_offset = 0;
        app.status_hint = "scrollback top · end/pgdn = live";
        app.dirty = True;
        return;
    }
    if key == "end" {
        set_follow_tail(app.proj, True);
        app.status_hint = "enter · ↑↓ history · esc quit";
        app.dirty = True;
        return;
    }
    if key == "escape" {
        if app.phase == "streaming" {
            cancel_active_turn();
            app.status_hint = "aborting…";
            app.dirty = True;
            return;
        }
        app.running = False;
        return;
    }
    if key == "up" {
        if app.phase != "streaming" {
            _history_up(app);
        }
        return;
    }
    if key == "down" {
        if app.phase != "streaming" {
            _history_down(app);
        }
        return;
    }
    if key == "enter" {
        if app.phase == "streaming" {
            return;
        }
        text = app.shell.prompt.draft.strip();
        if not text {
            return;
        }
        shell_submit(app.session, app.shell);
        if text.startswith("/") {
            reply = _run_slash(app, text);
            if reply {
                _push_turn(app, "tool", reply);
            }
            app.dirty = True;
            return;
        }
        # Context-expansion seam: @path[:10-20] become fenced <file>
        # blocks and a leading !cmd becomes a <command_output> block.
        # Any unexpected expansion failure degrades to the raw text rather
        # than killing the turn. Transcript still displays the raw line.
        expanded: str = text;
        try {
            expanded = _expand_quoted_context(os.getcwd(), text);
        } except Exception {
            expanded = text;
        }
        _begin_assistant_reply(app, text, expanded);
        return;
    }
    if key == "backspace" {
        if app.shell.prompt.draft {
            editor_backspace(app.shell.prompt);
            # Leave history-browse mode on manual edits (matches editor_insert).
            app.shell.prompt.history_index = -1;
            app.dirty = True;
        }
        return;
    }
    if key == "ctrl+u" {
        shell_cancel(app.session, app.shell);
        # Gap: neither AblePrompt.on_cancel nor shell_cancel resets history
        # state — no editor API op covers "clear draft + exit browse mode".
        app.shell.prompt.history_index = -1;
        app.dirty = True;
        return;
    }
    if key == "ctrl+d" {
        if not app.shell.prompt.draft {
            app.running = False;
        }
        return;
    }
}


def _handle_host_events(app: LiveShell, events: list[HostEvent]) {
    for event in coalesce_events(events) {
        if isinstance(event, TextEvent) {
            if app.picker is not None {
                # Picker input mode owns typed characters while open.
                for ch in event.text {
                    _handle_picker_key(app, ch);
                }
                continue;
            }
            if app.shell.approval is not None {
                if event.text in ["a", "y", "r", "n"] {
                    _handle_key(app, event.text);
                }
                continue;
            }
            if app.phase == "streaming" {
                continue;
            }
            shell_insert_text(app.session, app.shell, event.text);
            app.dirty = True;
        } elif isinstance(event, KeyEvent) {
            _handle_key(app, event.key);
        } elif isinstance(event, PasteEvent) {
            if app.shell.approval is None and app.phase != "streaming" and app.picker is None {
                shell_insert_text(app.session, app.shell, event.text);
                app.dirty = True;
            }
        }
    }
}
