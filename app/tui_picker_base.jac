"""Shared picker state transitions."""
import from tui_state { LiveShell }
import from ui.screen { shell_open_approval, shell_close_approval }
"""Open a generic list-picker on the shared overlay node (one at a time).
rows are display labels; ids map 1:1 onto action payloads. When
extra_last_input is set, a trailing "type name…" row flips the picker into
free-text input mode on enter."""
def _open_picker(
    app: LiveShell,
    title: str,
    rows: list[str],
    ids: list[str],
    extra_last_input: bool = False,
    multi: bool = False,
) -> bool {
    if app.picker is not None or app.ui_modal is not None or app.shell.approval is not None {
        return False;
    }
    options = list(rows);
    full_ids = list(ids);
    if extra_last_input {
        options.append("type name…");
        full_ids.append("__type__");
    }
    if not options {
        return False;
    }
    app.picker = {
        "title": title,
        "options": options,
        "ids": full_ids,
        "selected": 0,
        "mode": "select",
        "draft": "",
        "multi": multi,
        "toggled": [],
        "filter": "",
        "prev_hint": app.status_hint,
    };
    shell_open_approval(app.session, app.shell);
    if multi {
        app.status_hint = "type filter · space toggle · enter insert · esc";
    } else {
        app.status_hint = "↑↓ move · enter choose · esc cancel";
    }
    app.dirty = True;
    return True;
}


"""Dismiss the picker and restore the pre-open status hint."""
def _close_picker(app: LiveShell) {
    p: any = app.picker;
    app.picker = None;
    shell_close_approval(app.session, app.shell);
    if p is not None {
        app.status_hint = str(p.get("prev_hint", app.status_hint));
    }
    app.dirty = True;
}
"""Multi-select rows narrowed by the picker's type-to-filter text.

Case-insensitive substring match over option labels; empty filter returns
the full lists. Both paint (_picker_lines) and key handling
(_handle_picker_key) go through this helper so the cursor index always
refers to the same visible rows. Pure over its input — replicated in
tui_overlays.test.jac (keep in sync)."""
def _multi_filtered(p: dict) -> tuple[list, list] {
    options: list = list(p.get("options", []));
    ids: list = list(p.get("ids", []));
    filt: str = str(p.get("filter", "")).strip().lower();
    if not filt {
        return (options, ids);
    }
    vis_options: list = [];
    vis_ids: list = [];
    for i in range(len(options)) {
        if filt in str(options[i]).lower() {
            vis_options.append(options[i]);
            vis_ids.append(str(ids[i]) if i < len(ids) else "");
        }
    }
    return (vis_options, vis_ids);
}
