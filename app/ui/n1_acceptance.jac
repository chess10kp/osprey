"""N1 acceptance harness — product bar independent of markup authoring.

VirtualTerminal scenarios: first paint, resize mid-stream, cancel, restore.
Run: `JACPATH=. jac run ui/n1_acceptance.jac` or `jac test ui/n1_acceptance.jac`.
"""

import from ui.runtime {
    create_session,
    dispose_session,
}

import from ui.renderer {
    create_renderer,
    render_frame,
    set_node_contract,
    set_node_content,
    mark_semantic_dirty,
    Renderer,
}

import from ui.layout_types {
    LayoutSpec,
    fill_axis,
    fixed_axis,
    grow_axis,
}

import from ui.virtual_terminal {
    VirtualTerminal,
}

import from ui.terminal {
    ProcessTerminal,
}

import from ui.input {
    InputNormalizer,
    KeyEvent,
}

import from ui.host {
    create_host_loop,
    run_host_tick,
    note_interrupt,
    host_events_to_effects,
}

import from ui.screen {
    build_main_shell,
    shell_insert_text,
    shell_cancel,
    shell_resize,
    shell_ids,
    ShellScreen,
}

import from agent.protocol {
    create_adapter,
    make_envelope,
    enqueue,
    drain_and_drive,
}


obj N1Result {
    has name: str = "",
        ok: bool = False,
        detail: str = "";
}


def _check(name: str, ok: bool, detail: str = "") -> N1Result {
    return N1Result(name=name, ok=ok, detail=detail);
}


def _wire_shell_content(
    renderer: Renderer, shell: ShellScreen, transcript: str, prompt: str
) {
    # Mirror screen.jac configure_main_shell_layout: screen fills the
    # renderer's viewport; header/status keep fixed 1-row, prompt 2-row;
    # transcript grows with vertical scroll.
    set_node_contract(
        renderer,
        shell.screen,
        LayoutSpec(width=fill_axis(), height=fill_axis()),
    );
    set_node_contract(
        renderer,
        shell.header,
        LayoutSpec(width=fill_axis(), height=fixed_axis(1)),
    );
    set_node_contract(
        renderer,
        shell.transcript,
        LayoutSpec(width=fill_axis(), height=grow_axis(1.0), scroll_vertical=True),
    );
    set_node_contract(
        renderer,
        shell.status,
        LayoutSpec(width=fill_axis(), height=fixed_axis(1)),
    );
    set_node_contract(
        renderer,
        shell.prompt,
        LayoutSpec(width=fill_axis(), height=fixed_axis(2)),
    );
    set_node_content(renderer, shell.header, ["Jackal"]);
    set_node_content(renderer, shell.transcript, [transcript] if transcript else [""]);
    set_node_content(renderer, shell.status, ["ready"]);
    set_node_content(renderer, shell.prompt, ["> " + prompt]);
}


def scenario_first_paint_no_full_clear() -> N1Result {
    handle = create_session();
    session = handle.session;
    shell = build_main_shell(session);
    term = VirtualTerminal(columns=40, rows=12);
    term.start();
    renderer = create_renderer(40, 12);
    _wire_shell_content(renderer, shell, "hello stream", "");
    term.clear_writes();
    frame = render_frame(renderer, shell.screen, term);
    ok = (
        frame.used_full_clear == False
        and frame.sync_wrapped == True
        and frame.cells_written > 0
    );
    dispose_session(session);
    return _check("first_paint_no_full_clear", ok, "cells=" + str(frame.cells_written));
}


def scenario_resize_mid_stream() -> N1Result {
    handle = create_session();
    session = handle.session;
    shell = build_main_shell(session);
    ids_before = shell_ids(shell);
    shell_insert_text(session, shell, "draft-keep");
    shell.transcript.source_id = "turn-1";
    shell.transcript.observed_revision = 3;
    shell_resize(session, shell, 60, 20);
    ids_after = shell_ids(shell);
    ok = (
        shell.prompt.draft == "draft-keep"
        and shell.transcript.source_id == "turn-1"
        and ids_before.prompt_id == ids_after.prompt_id
        and ids_before.transcript_id == ids_after.transcript_id
    );
    dispose_session(session);
    return _check("resize_mid_stream_preserves_ids", ok);
}


def scenario_cancel_clears_draft() -> N1Result {
    handle = create_session();
    session = handle.session;
    shell = build_main_shell(session);
    shell_insert_text(session, shell, "abort me");
    shell_cancel(session, shell);
    ok = shell.prompt.draft == "";
    dispose_session(session);
    return _check("cancel_clears_draft", ok);
}


def scenario_protocol_cancel_drive() -> N1Result {
    handle = create_session();
    session = handle.session;
    shell = build_main_shell(session);
    adapter = create_adapter("n1");
    enqueue(
        adapter.queue,
        make_envelope(kind="status", payload={"phase": "streaming"}, turn_id="t1"),
    );
    enqueue(
        adapter.queue,
        make_envelope(
            kind="turn_cancelled",
            turn_id="t1",
            correlation_id="t1",
            payload={"reason": "ctrl-c"},
        ),
    );
    drain_and_drive(adapter, shell);
    ok = shell.status.phase == "cancelled" or shell.status.phase == "ready";
    dispose_session(session);
    return _check("protocol_cancel_drive", ok, "phase=" + shell.status.phase);
}


def scenario_esc_timeout() -> N1Result {
    norm = InputNormalizer();
    norm.esc_timeout_ms = 50;
    first = norm.feed("\x1b");
    # A lone ESC must be buffered, never emitted immediately — otherwise
    # the escape-timeout policy below could not distinguish early vs late.
    assert first == [];
    norm.arm_esc(0.0);
    early = norm.flush_esc_timeout(10.0);
    late = norm.flush_esc_timeout(60.0);
    ok = early == [] and len(late) == 1 and (late[0] as KeyEvent).key == "escape";
    return _check("esc_timeout_policy", ok);
}


def scenario_host_interrupt_effect() -> N1Result {
    loop = create_host_loop();
    term = VirtualTerminal(columns=20, rows=5);
    term.start();
    note_interrupt(loop);
    events = run_host_tick(loop, term, 0.0, now_ms=0.0);
    effects = host_events_to_effects(events);
    found_cancel = False;
    for e in effects {
        if e.get("kind") == "cancel" {
            found_cancel = True;
        }
    }
    ok = found_cancel;
    term.stop();
    return _check("host_interrupt_maps_to_cancel", ok);
}


def scenario_restore_idempotent() -> N1Result {
    # ProcessTerminal.restore without a TTY start must still be safe.
    term = ProcessTerminal();
    term.restore();
    term.restore();
    ok = term.restored == True;
    return _check("process_terminal_restore_idempotent", ok);
}


def scenario_process_terminal_flag_restore() -> N1Result {
    # Simulate mid-session flags (no TTY start) and assert stop tears them down.
    term = ProcessTerminal();
    term.started = True;
    term.restored = False;
    term.alternate_screen = True;
    term.bracketed_paste = True;
    term.cursor_visible = False;
    term.sync_active = True;
    term.restore();
    ok = (
        term.restored
        and not term.started
        and not term.alternate_screen
        and not term.bracketed_paste
        and term.cursor_visible
        and not term.sync_active
    );
    term.restore();
    ok = ok and term.restored;
    return _check("process_terminal_flag_restore", ok);
}


def scenario_pty_soak_virtual() -> N1Result {
    # Multi-frame soak: stream + resize + host interrupt + restore.
    handle = create_session();
    session = handle.session;
    shell = build_main_shell(session);
    term = VirtualTerminal(columns=40, rows=12);
    term.start();
    renderer = create_renderer(40, 12);
    loop = create_host_loop();
    adapter = create_adapter("n1-soak");
    full_clears = 0;
    frames = 0;
    max_cells = 0;
    for i in range(48) {
        if i % 7 == 0 {
            cols = 40 + (i % 3) * 4;
            rows_n = 12 + (i % 2);
            shell_resize(session, shell, cols, rows_n);
            term.inject_resize(cols, rows_n);
            renderer = create_renderer(term.columns, term.rows);
        }
        chunk = "stream-" + str(i);
        enqueue(
            adapter.queue,
            make_envelope(
                kind="text_delta",
                payload={"text": chunk},
                turn_id="t1",
            ),
        );
        drain_and_drive(adapter, shell);
        transcript = adapter.stream_buf if adapter.stream_buf else chunk;
        _wire_shell_content(renderer, shell, transcript, "draft");
        mark_semantic_dirty(renderer, shell.transcript);
        frame = render_frame(renderer, shell.screen, term);
        frames += 1;
        if frame.used_full_clear {
            full_clears += 1;
        }
        if frame.cells_written > max_cells {
            max_cells = frame.cells_written;
        }
        if i % 11 == 0 {
            term.inject("x");
            run_host_tick(loop, term, 0.0, now_ms=float(i) * 10.0);
        }
    }
    note_interrupt(loop);
    effects = host_events_to_effects(
        run_host_tick(loop, term, 0.0, now_ms=9999.0)
    );
    has_cancel = False;
    for e in effects {
        if e.get("kind") == "cancel" {
            has_cancel = True;
        }
    }
    shell_cancel(session, shell);
    term.stop();
    term.restore();
    dispose_session(session);
    ok = (
        frames == 48
        and full_clears == 0
        and has_cancel
        and term.restored
        and shell.prompt.draft == ""
        and max_cells > 0
    );
    return _check(
        "pty_soak_virtual",
        ok,
        "frames="
        + str(frames)
        + " clears="
        + str(full_clears)
        + " max_cells="
        + str(max_cells),
    );
}


def scenario_second_frame_retained() -> N1Result {
    handle = create_session();
    session = handle.session;
    shell = build_main_shell(session);
    term = VirtualTerminal(columns=40, rows=12);
    term.start();
    renderer = create_renderer(40, 12);
    _wire_shell_content(renderer, shell, "line one", "p");
    frame1 = render_frame(renderer, shell.screen, term);
    set_node_content(renderer, shell.transcript, ["line one!"]);
    mark_semantic_dirty(renderer, shell.transcript);
    frame2 = render_frame(renderer, shell.screen, term);
    ok = (
        frame1.cells_written > 0
        and frame2.cells_written < frame1.cells_written
        and frame2.used_full_clear == False
    );
    dispose_session(session);
    return _check(
        "second_frame_retained_damage",
        ok,
        "f1=" + str(frame1.cells_written) + " f2=" + str(frame2.cells_written),
    );
}


def run_n1_acceptance() -> bool {
    results: list[N1Result] = [
        scenario_first_paint_no_full_clear(),
        scenario_resize_mid_stream(),
        scenario_cancel_clears_draft(),
        scenario_protocol_cancel_drive(),
        scenario_esc_timeout(),
        scenario_host_interrupt_effect(),
        scenario_restore_idempotent(),
        scenario_process_terminal_flag_restore(),
        scenario_pty_soak_virtual(),
        scenario_second_frame_retained(),
    ];
    all_ok = True;
    for r in results {
        mark = "PASS" if r.ok else "FAIL";
        print(mark + "  " + r.name + (("  " + r.detail) if r.detail else ""));
        if not r.ok {
            all_ok = False;
        }
    }
    print("N1 acceptance: " + ("PASS" if all_ok else "FAIL"));
    return all_ok;
}


test "n1 acceptance suite passes" {
    assert run_n1_acceptance();
}


with entry {
    ok = run_n1_acceptance();
    if not ok {
        raise SystemExit(1);
    }
}
