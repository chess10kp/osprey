"""Painting and overlay rendering for the native LiveShell."""
import os;
import from tui.state { LiveShell, SLASH_BUILTINS }
import from tui.core {
    _rule, _pad_to, _prompt_prefix,
    _status_line, _prompt_lines,
}
import from core.edit { compute_unified_diff }
import from ui.model { UiNode }
import from ui.transcript { materialize_visible }
import from ui.layout { LayoutSpec, OverlayAnchor, fill_axis, fixed_axis }
import from ui.renderer {
    render_frame, set_node_content, set_node_contract,
    mark_semantic_dirty, mark_layout_dirty, request_cursor,
}
import from ui.width { display_width, truncate_text }
import from tui.picker_base { _multi_filtered }
import from agent.session { list_commands }
"""Unified-diff preview lines for a pending write_file/edit_file approval.
Capped at 20 diff lines with a trailing truncation marker; returns [] when
no old/new text pair can be assembled (missing args, unreadable baseline)."""
def _approval_diff_preview(name: str, args: dict[str, any]) -> list[str] {
    old_text = "";
    new_text = "";
    if name == "edit_file" {
        old_text = str(args.get("old_text", ""));
        new_text = str(args.get("new_text", ""));
    } elif name == "write_file" {
        new_text = str(args.get("content", ""));
        path = str(args.get("path", ""));
        if path {
            full = path if os.path.isabs(path) else os.path.join(os.getcwd(), path);
            # Baseline is read from disk at render time (preview only);
            # a missing file means every line is an addition.
            if os.path.isfile(full) {
                try {
                    fh = open(full);
                    old_text = fh.read();
                    fh.close();
                } except Exception {
                    return [];
                }
            }
        } else {
            return [];
        }
    } else {
        return [];
    }
    diff = compute_unified_diff(old_text, new_text);
    if not diff or diff.startswith("ERROR") {
        return [];
    }
    raw: list[str] = diff.split("\n");
    cap = 20;
    shown: list[str] = raw[:cap];
    out: list[str] = ["diff:"];
    for ln in shown {
        prefix = " ";
        if ln.startswith("+") or ln.startswith("-") or ln.startswith("@") {
            prefix = "";
        }
        out.append(prefix + ln);
    }
    more = len(raw) - cap;
    if more > 0 {
        out.append("… " + str(more) + " more lines");
    }
    return out;
}


"""Approval overlay body — REAL pending-approval data: tool name plus cmd
(run_command), target path and old/new char counts (write_file/edit_file)
or generic key=value pairs, then a capped unified-diff preview."""
def _approval_lines(app: LiveShell) -> list[str] {
    inner = 46;
    head = "TOOL APPROVAL · " + app.appr_tool_name;
    body: list[str] = [];
    args: any = app.appr_args;
    if isinstance(args, dict) {
        if app.appr_tool_name == "run_command" {
            body.append("$ " + str(args.get("cmd", "")));
            timeout_secs = str(args.get("timeout_secs", ""));
            if timeout_secs {
                body.append("timeout " + timeout_secs + "s");
            }
        } elif app.appr_tool_name == "write_file" {
            body.append(str(args.get("path", "")));
            body.append("+ " + str(len(str(args.get("content", "")))) + " chars");
        } elif app.appr_tool_name == "edit_file" {
            body.append(str(args.get("path", "")));
            body.append(
                "- " + str(len(str(args.get("old_text", ""))))
                + " / + " + str(len(str(args.get("new_text", "")))) + " chars"
            );
        } else {
            parts: list[str] = [];
            for pair in args.items() {
                parts.append(str(pair[0]) + "=" + str(pair[1])[:40]);
            }
            body.append((", ".join(parts))[:inner - 6]);
        }
        body.extend(_approval_diff_preview(app.appr_tool_name, args));
    }
    if not body {
        body.append("(no details available)");
    }
    lines: list[str] = [
        "╭" + _rule(inner, "─") + "╮",
        "│" + _pad_to("  " + head, inner) + "│",
        "│" + _pad_to("", inner) + "│",
    ];
    for ln in body {
        lines.append("│" + _pad_to("  " + ln, inner) + "│");
    }
    lines.append("│" + _pad_to("", inner) + "│");
    lines.append("│" + _pad_to("  [a] Accept    [r] Reject    [esc]", inner) + "│");
    lines.append("╰" + _rule(inner, "─") + "╯");
    return lines;
}


"""Foreground extension-ui modal content — painted into the shared
overlay node while app.ui_modal is set."""
def _ui_modal_lines(app: LiveShell) -> list[str] {
    m: any = app.ui_modal;
    inner = 46;
    method = str(m.get("method", ""));
    head = "? [ui] " + method.upper();
    body: list[str] = [];
    title = str(m.get("title", ""));
    message = str(m.get("message", ""));
    placeholder = str(m.get("placeholder", ""));
    if title {
        body.append(title[:inner - 4]);
    }
    if message {
        body.append(message[:inner - 4]);
    }
    body.append("");
    if method == "select" {
        options: list = list(m.get("options", []));
        sel = int(m.get("selected", 0));
        i = 0;
        for opt in options[:8] {
            mark = ">" if i == sel else " ";
            body.append(mark + " " + str(opt)[:inner - 6]);
            i += 1;
        }
        body.append("");
        body.append("  [\u2191\u2193] move   [enter] choose   [esc] cancel");
    } elif method == "confirm" {
        body.append("  [y] yes    [n/Esc] no");
    } else {
        draft = str(m.get("draft", ""));
        shown = draft if draft else placeholder;
        body.append("  > " + shown[:inner - 6] + "\u258c");
        body.append("");
        body.append("  [enter] submit (empty allowed)   [esc] cancel");
    }
    lines: list[str] = ["\u256d" + _rule(inner, "\u2500") + "\u256e"];
    lines.append("\u2502" + _pad_to("  " + head, inner) + "\u2502");
    for ln in body {
        lines.append("\u2502" + _pad_to("  " + ln, inner) + "\u2502");
    }
    lines.append("\u2570" + _rule(inner, "\u2500") + "\u256f");
    return lines;
}


"""Generic list-picker overlay body (model chooser / resume chooser).
Mirrors the extension-modal box styling; select mode shows rows with a
">" cursor, input mode shows an editable draft line."""
def _picker_lines(app: LiveShell) -> list[str] {
    p: any = app.picker;
    inner = 46;
    head = "? " + str(p.get("title", ""));
    body: list[str] = [];
    if str(p.get("mode", "select")) == "input" {
        draft = str(p.get("draft", ""));
        if str(p.get("title", "")) == "LOGIN" {
            provider_id = str(p.get("providerId", ""));
            body.append("  provider: " + provider_id[:inner - 14]);
            shown = ("*" * len(draft)) if draft else "(paste API key)";
        } else {
            shown = draft if draft else "(type a model id)";
        }
        body.append("  > " + shown[:inner - 8] + "▌");
    } elif bool(p.get("multi", False)) {
        # Multi-select (EXPLORER): optional type-to-filter row, [x]/[ ]
        # toggle boxes, and a sliding 8-row window over the FILTERED rows so
        # the cursor stays visible in long file lists.
        vis: tuple[list, list] = _multi_filtered(p);
        vis_options: list = vis[0];
        vis_ids: list = vis[1];
        toggled: list = list(p.get("toggled", []));
        filt: str = str(p.get("filter", ""));
        if filt {
            body.append("/ " + filt + "▌");
        }
        if not vis_options {
            body.append("(no matches)");
        }
        sel = min(int(p.get("selected", 0)), max(0, len(vis_options) - 1));
        start = 0;
        if sel >= 8 {
            start = sel - 7;
        }
        window: any = vis_options[start:start + 8];
        i = start;
        for opt in window {
            rid = str(vis_ids[i]) if i < len(vis_ids) else "";
            box = "x" if rid in toggled else " ";
            mark = ">" if i == sel else " ";
            body.append(mark + " [" + box + "] " + str(opt)[:inner - 10]);
            i += 1;
        }
        more = len(vis_options) - start - len(window);
        if more > 0 {
            body.append("… " + str(more) + " more");
        }
    } else {
        options2: list = list(p.get("options", []));
        sel = int(p.get("selected", 0));
        i = 0;
        for opt in options2[:8] {
            mark = ">" if i == sel else " ";
            body.append(mark + " " + str(opt)[:inner - 6]);
            i += 1;
        }
        more = len(options2) - 8;
        if more > 0 {
            body.append("… " + str(more) + " more");
        }
    }
    body.append("");
    if str(p.get("mode", "select")) == "input" {
        if str(p.get("title", "")) == "LOGIN" {
            body.append("  paste API key · [enter] save · [esc] cancel");
        } else {
            body.append("  type id · [enter] submit   [esc] cancel");
        }
    } elif bool(p.get("multi", False)) {
        body.append("  type filter · [space] toggle · enter insert · esc");
    } else {
        body.append("  [↑↓] move   [enter] choose   [esc] cancel");
    }
    lines: list[str] = [
        "╭" + _rule(inner, "─") + "╮",
        "│" + _pad_to("  " + head, inner) + "│",
    ];
    for ln in body {
        lines.append("│" + _pad_to("  " + ln, inner) + "│");
    }
    lines.append("╰" + _rule(inner, "─") + "╯");
    return lines;
}
"""Paint lines into the shared overlay node (picker/modal/approval owner).
The caller has already decided ownership; this just guards the optional node."""
def _paint_overlay(app: LiveShell, lines: list[str]) {
    ov: UiNode | None = app.shell.approval;
    if ov is None {
        return;
    }
    set_node_contract(
        app.renderer,
        ov,
        LayoutSpec(
            width=fixed_axis(48),
            height=fixed_axis(len(lines)),
            overlay_anchor=OverlayAnchor.CENTER,
        ),
    );
    set_node_content(app.renderer, ov, lines);
    mark_semantic_dirty(app.renderer, ov);
    mark_layout_dirty(app.renderer, ov);
}


# ==================== slash-command autocomplete ====================

"""Slash-command candidates for the typed prefix: built-ins plus extension
commands (list_commands()), deduped, alphabetical, capped at 6. Each entry
is [name_with_slash, description]. Empty when the draft is not a bare
command word."""
def _slash_candidates(draft: str) -> list[list[str]] {
    text = draft.strip();
    if not text.startswith("/") or " " in text {
        return [];
    }
    token: str = text;
    descs: dict[str, str] = {};
    for bname in SLASH_BUILTINS {
        full = "/" + str(bname);
        descs[full] = str(SLASH_BUILTINS[bname]);
    }
    try {
        cmds = list_commands();
    } except Exception {
        cmds = {};
    }
    if isinstance(cmds, dict) {
        for cname in cmds {
            full = "/" + str(cname);
            if full in descs {
                continue;  # built-in shadows same-named extension command
            }
            meta: dict = cmds[cname] if isinstance(cmds[cname], dict) else {};
            descs[full] = str(meta.get("description", "") or "");
        }
    }
    out: list[list[str]] = [];
    for name in sorted(descs) {
        if name.startswith(token) {
            out.append([name, descs[name]]);
            if len(out) >= 6 {
                break;
            }
        }
    }
    return out;
}


"""Popup visibility + candidates in one shot: hidden while any modal,
picker or approval owns the screen, when the draft is not a bare "/word",
or when the user dismissed this exact draft with esc. Returns the match
list or None."""
def _slash_popup_state(app: LiveShell) -> list[list[str]] | None {
    if app.picker is not None or app.ui_modal is not None or app.shell.approval is not None {
        return None;
    }
    text = app.shell.prompt.draft.strip();
    if not text.startswith("/") or " " in text {
        return None;
    }
    if text == app.slash_dismissed {
        return None;
    }
    matches = _slash_candidates(text);
    if not matches {
        return None;
    }
    return matches;
}


""">-cursor rows for the popup (selected entry marked, description
truncated to the terminal width). Selection clamps into range so stale
indices from earlier filters never crash the paint."""
def _slash_popup_rows(app: LiveShell, matches: list[list[str]]) -> list[str] {
    max_w = max(10, app.columns - 2);
    sel = int(app.slash_sel);
    if sel >= len(matches) {
        sel = len(matches) - 1;
    }
    if sel < 0 {
        sel = 0;
    }
    rows: list[str] = [];
    i = 0;
    for m in matches {
        mark = ">" if i == sel else " ";
        label = str(m[0]);
        desc = str(m[1]);
        if desc {
            label += " — " + desc;
        }
        rows.append(truncate_text(mark + " " + label, max_w, ellipsis="…"));
        i += 1;
    }
    return rows;
}


def _transcript_lines(app: LiveShell) -> list[str] {
    win = materialize_visible(app.proj);
    if win.lines {
        return win.lines;
    }
    # Empty-state composition — one quiet invitation.
    w = max(10, app.columns - 2);
    return [
        "",
        truncate_text("  the graph is live.", w, ellipsis="…"),
        truncate_text("  type below — jackal answers in this frame.", w, ellipsis="…"),
        "",
        truncate_text("  try:  explain retained damage", w, ellipsis="…"),
    ];
}


def _paint(app: LiveShell) {
    lines = _transcript_lines(app);
    status = _status_line(app);
    prompt_lines = _prompt_lines(app);

    # Slash autocomplete: extra rows painted ABOVE the prompt box inside the
    # prompt node; its fixed contract grows/shrinks with the popup each frame.
    popup: list[list[str]] | None = _slash_popup_state(app);
    popup_rows: list[str] = [];
    if popup is not None {
        popup_rows = _slash_popup_rows(app, popup);
    }
    set_node_contract(
        app.renderer,
        app.shell.prompt,
        LayoutSpec(
            width=fill_axis(),
            height=fixed_axis(3 + len(popup_rows)),
        ),
    );

    # Shared overlay node: local pickers own it first, then extension modals,
    # then tool approvals.
    overlay: list[str] | None = None;
    if app.picker is not None {
        overlay = _picker_lines(app);
    } elif app.ui_modal is not None {
        overlay = _ui_modal_lines(app);
    } elif app.shell.approval is not None {
        overlay = _approval_lines(app);
    }
    if overlay is not None {
        _paint_overlay(app, overlay);
    }

    set_node_content(app.renderer, app.shell.transcript, lines);
    set_node_content(app.renderer, app.shell.status, [status]);
    set_node_content(app.renderer, app.shell.prompt, popup_rows + prompt_lines);
    mark_semantic_dirty(app.renderer, app.shell.transcript);
    mark_semantic_dirty(app.renderer, app.shell.status);
    mark_semantic_dirty(app.renderer, app.shell.prompt);
    mark_layout_dirty(app.renderer, app.shell.screen);

    # Caret sits after the mode prefix + draft inside the box (col 1 is │).
    prefix_w = display_width(_prompt_prefix(app.mode));
    draft_w = display_width(app.shell.prompt.draft);
    cursor_col = 1 + prefix_w + draft_w;
    max_col = app.columns - 2;
    if cursor_col > max_col {
        cursor_col = max_col;
    }
    request_cursor(
        app.renderer,
        app.shell.prompt,
        row_offset=1 + len(popup_rows),
        col_offset=cursor_col,
    );
}


def _render(app: LiveShell) {
    if not app.dirty {
        return;
    }
    _paint(app);
    frame = render_frame(app.renderer, app.shell.screen, app.term);
    if frame.cursor_row >= 0 {
        app.term.show_cursor();
    } else {
        app.term.hide_cursor();
    }
    app.dirty = False;
}
