"""Jackal TUI coordinator. Behavior lives in responsibility modules."""

import sys;
import os;
import queue;
import from tui_state { LiveShell }
import from tui_picker_actions { _hydrate_auth_environment }
import from tui_core { _push_turn, _install_layout }
import from tui_overlay { _render }
import from tui_runtime { _apply_resize }
import from tui_input { _tick_app, _handle_host_events }
import from agent.session { session_boot, get_model, set_mode, get_mode }
import from ui.runtime { create_session, dispose_session }
import from ui.screen { build_main_shell, install_shell_contracts }
import from ui.transcript { bind_transcript, set_follow_tail }
import from ui.renderer { create_renderer }
import from ui.terminal { ProcessTerminal, read_terminal_size }
import from ui.input { InputNormalizer }
import from ui.progress_bar { ProgressBar }

def create_live_shell() -> LiveShell {
    (cols, rows) = read_terminal_size(80, 24);
    handle = create_session();
    session = handle.session;
    shell = build_main_shell(session);
    install_shell_contracts(session, shell, "live.transcript");
    proj = bind_transcript(
        shell.transcript,
        "live.transcript",
        width=max(12, cols - 2),
        height=max(4, rows - 7),
    );
    set_follow_tail(proj, True);
    term = ProcessTerminal();
    term.columns = cols;
    term.rows = rows;
    renderer = create_renderer(cols, rows);
    progress = ProgressBar(key="live_progress", value=0.0);
    app = LiveShell(
        session=session,
        shell=shell,
        proj=proj,
        renderer=renderer,
        term=term,
        normalizer=InputNormalizer(),
        progress=progress,
        columns=cols,
        rows=rows,
        mode=get_mode(),
    );
    _install_layout(app);
    _push_turn(
        app,
        "system",
        "session attached · detached graph · retained paint\n"
        + "say something — watch the stream, then the approval modal",
    );
    return app;
}


def run_tui() {
    requested_mode: str = os.environ.get("JACKAL_MODE", "");
    if requested_mode {
        try {
            set_mode(requested_mode);
        } except ValueError as e {
            print("jackal: " + str(e));
            raise SystemExit(2);
        }
    }
    # Extensions load per .jackal/extensions.json (parallel sidecar when declared).
    try {
        session_boot(interactive_ui=True);
    } except Exception {
    }
    _hydrate_auth_environment();
    app = create_live_shell();
    app.cmd_q = queue.Queue();
    app.term.start();
    try {
        # Inside the try so any failure after start() unwinds through the
        # finally below and restores the host terminal (replaces atexit).
        app.term.set_title("Jackal — " + get_model());
        app.dirty = True;
        _render(app);
        while app.running {
            (cols, rows) = app.term.size();
            if cols != app.columns or rows != app.rows {
                _apply_resize(app, cols, rows);
            }
            raw = app.term.poll_input(0.04);
            if app.term.eof {
                app.running = False;
                break;
            }
            if raw {
                events = app.normalizer.feed(raw);
                _handle_host_events(app, events);
            } elif app.normalizer.buffer == "\x1b" {
                events = app.normalizer.flush_buffer();
                _handle_host_events(app, events);
            }
            _tick_app(app);
            _render(app);
        }
    } except KeyboardInterrupt {
        app.running = False;
    } finally {
        try {
            app.term.hide_cursor();
            app.term.stop();
        } except Exception {
        }
        dispose_session(app.session);
    }
}


with entry {
    if not sys.stdin.isatty() or not sys.stdout.isatty() {
        print("jackal tui needs a real TTY.");
        raise SystemExit(1);
    }
    run_tui();
}
