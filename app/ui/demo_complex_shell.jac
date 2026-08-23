"""Complex OSP UI demo: headless VirtualTerminal validation harness.

This does NOT open a real TUI. It drives the P0 framework on an in-memory
terminal and prints a PASS/FAIL report. For an interactive session use:

  JACPATH=. jac run ui/demo_live_shell.jac

Headless validation:

  JACPATH=. jac run ui/demo_complex_shell.jac

Test:

  JAC_TEST_JOBS=0 jac test ui/demo_complex_shell.jac
"""

import from time { perf_counter }

import from ui.model {
    node_id,
}

import from ui.runtime {
    create_session,
    dispose_session,
    ui_jids_reachable_from_persistent_root,
}

import from ui.bindings {
    is_empty,
}

import from ui.screen {
    build_main_shell,
    install_shell_contracts,
    shell_ids,
    shell_insert_text,
    shell_submit,
    shell_open_approval,
    shell_close_approval,
    shell_resize,
}

import from ui.transcript {
    TranscriptMessage,
    bind_transcript,
    apply_transcript_revision,
    materialize_visible,
    set_follow_tail,
}

import from ui.layout_types {
    LayoutSpec,
    fill_axis,
    fixed_axis,
    grow_axis,
}

import from ui.renderer {
    create_renderer,
    render_frame,
    set_node_content,
    set_node_contract,
    mark_semantic_dirty,
    mark_layout_dirty,
    request_cursor,
    frame_used_full_clear,
}

import from ui.virtual_terminal {
    VirtualTerminal,
}

import from ui.progress_bar {
    ProgressBar,
    SetProgress,
    render_progress,
}

import from ui.inspect {
    validate_invariants,
    dump_graph,
    dump_bindings,
    dump_lifetimes,
}

import from agent.protocol {
    create_adapter,
    make_envelope,
    enqueue,
    dequeue,
    drive_screen,
    cancel_turn,
    queue_stats,
}


obj DemoStep {
    has name: str,
        ok: bool,
        detail: str = "";
}


obj DemoReport {
    has passed: bool = False,
        steps: list[DemoStep] = [],
        cells_written_total: int = 0,
        coalesced_deltas: int = 0,
        frames_rendered: int = 0,
        invariant_findings: int = 0,
        stable_ids: bool = False,
        disposed_clean: bool = False,
        latency_ms: float = 0.0,
        last_frame: str = "",
        graph_dump: str = "",
        binding_dump: str = "";
}


def _step(demo: DemoReport, name: str, ok: bool, detail: str = "") {
    demo.steps.append(DemoStep(name=name, ok=ok, detail=detail));
    if not ok {
        demo.passed = False;
    }
}


def _frame_text(rows: list[str]) -> str {
    border = "+" + ("-" * 78) + "+";
    lines: list[str] = [border];
    for row in rows {
        clipped = row;
        if len(clipped) > 78 {
            clipped = clipped[:78];
        }
        pad = 78 - len(clipped);
        lines.append("|" + clipped + (" " * pad) + "|");
    }
    lines.append(border);
    return "\n".join(lines);
}


def _install_shell_layout(renderer: any, shell: any, columns: int, rows: int) {
    _ = columns;
    _ = rows;
    # Mirror screen.jac configure_main_shell_layout (M6 LayoutSpec specs).
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
}


def _paint_shell(
    renderer: any,
    shell: any,
    header_line: str,
    transcript_lines: list[str],
    status_line: str,
    prompt_lines: list[str],
    overlay_lines: list[str] | None = None,
) {
    set_node_content(renderer, shell.header, [header_line]);
    set_node_content(renderer, shell.transcript, transcript_lines);
    set_node_content(renderer, shell.status, [status_line]);
    set_node_content(renderer, shell.prompt, prompt_lines);
    mark_semantic_dirty(renderer, shell.header);
    mark_semantic_dirty(renderer, shell.transcript);
    mark_semantic_dirty(renderer, shell.status);
    mark_semantic_dirty(renderer, shell.prompt);
    mark_layout_dirty(renderer, shell.screen);
    if overlay_lines is not None and shell.approval is not None {
        set_node_contract(
            renderer,
            shell.approval,
            LayoutSpec(
                width=fixed_axis(48),
                height=fixed_axis(max(3, len(overlay_lines))),
            ),
        );
        set_node_content(renderer, shell.approval, overlay_lines);
        mark_semantic_dirty(renderer, shell.approval);
        mark_layout_dirty(renderer, shell.approval);
    }
}


"""Run the full complex demo and return a structured result."""
def run_complex_shell_demo(
    columns: int = 80,
    rows: int = 24,
    verbose: bool = False,
) -> DemoReport {
    demo = DemoReport(passed=True);
    t0 = perf_counter();

    handle = create_session();
    session = handle.session;
    shell = build_main_shell(session);
    ids0 = shell_ids(shell);
    _step(
        demo,
        "boot_session",
        session.ui_root is not None and ids0.prompt_id != "",
        "session=" + handle.ui_root_id[:8],
    );

    install_shell_contracts(session, shell, "demo.transcript");
    _step(
        demo,
        "bindings_and_cursor",
        not is_empty(session.bindings),
        "bound transcript + cursor capability",
    );

    proj = bind_transcript(
        shell.transcript,
        "demo.transcript",
        width=columns - 2,
        height=max(6, rows - 6),
    );
    set_follow_tail(proj, True);

    seed: list[TranscriptMessage] = [
        TranscriptMessage(
            message_id="m0",
            content="system: Jackal OSP UI complex demo online.",
            content_rev=1,
        ),
        TranscriptMessage(
            message_id="m1",
            content="user: refactor the retained renderer damage union path",
            content_rev=1,
        ),
    ];
    apply_transcript_revision(proj, 1, seed);
    _step(
        demo,
        "transcript_bind",
        shell.transcript.source_id == "demo.transcript"
        and shell.transcript.observed_revision == 1,
        "messages=" + str(len(proj.messages)),
    );

    adapter = create_adapter(session_id=handle.ui_root_id, capacity=64);
    turn_id = "turn-demo-1";
    for chunk in ["I'll ", "inspect ", "layout.jac ", "and ", "renderer.jac…"] {
        enqueue(
            adapter.queue,
            make_envelope(
                kind="text_delta",
                session_id=adapter.session_id,
                turn_id=turn_id,
                correlation_id=turn_id,
                payload={"text": chunk},
            ),
        );
    }
    enqueue(
        adapter.queue,
        make_envelope(
            kind="status",
            session_id=adapter.session_id,
            turn_id=turn_id,
            payload={"phase": "streaming"},
        ),
    );
    stats = queue_stats(adapter.queue);
    demo.coalesced_deltas = stats.coalesced;
    _step(
        demo,
        "protocol_coalesce",
        stats.coalesced >= 4 and stats.depth <= 2,
        "coalesced=" + str(stats.coalesced) + " depth=" + str(stats.depth),
    );

    while True {
        env = dequeue(adapter.queue);
        if env is None {
            break;
        }
        drive_screen(adapter, shell, env);
    }
    _step(
        demo,
        "drive_status",
        shell.status.phase == "streaming",
        "phase=" + shell.status.phase,
    );

    shell_insert_text(session, shell, "also watch resize mid-stream");
    effects = shell_submit(session, shell);
    _step(
        demo,
        "prompt_submit",
        len(effects) == 1 and shell.prompt.draft == "",
        "SendPrompt effect queued",
    );

    # Extend transcript with a long stream + enough older noise to leave
    # early messages off-screen under follow_tail.
    streamed: list[TranscriptMessage] = list(seed);
    for i in range(40) {
        streamed.append(
            TranscriptMessage(
                message_id="old_" + str(i),
                content=(
                    "archive note "
                    + str(i)
                    + ": prior turn context that should stay off-screen"
                ),
                content_rev=1,
            )
        );
    }
    assistant = (
        "assistant: tracing Child ranks → measure → damage union. "
        + "Unicode check: 日本語 wide glyphs + combining e\u0301."
    );
    streamed.append(
        TranscriptMessage(
            message_id="m2",
            content=assistant,
            content_rev=1,
        )
    );
    apply_transcript_revision(proj, 2, streamed);
    win = materialize_visible(proj);
    _step(
        demo,
        "transcript_virtualize",
        len(win.lines) > 0 and proj.view.follow_tail == True,
        "visible_lines=" + str(len(win.lines)),
    );

    # Mutate an early archive message that sits above the follow-tail window.
    offscreen = list(streamed);
    offscreen[2] = TranscriptMessage(
        message_id="old_0",
        content="archive note 0: mutated off-screen",
        content_rev=2,
    );
    apply_transcript_revision(proj, 3, offscreen);
    _step(
        demo,
        "offscreen_no_damage",
        proj.last_damage == False,
        "follow_tail viewport unchanged",
    );

    term = VirtualTerminal(columns=columns, rows=rows);
    term.start();
    renderer = create_renderer(columns, rows);
    _install_shell_layout(renderer, shell, columns, rows);

    progress = ProgressBar(key="tool_progress", value=0.0);
    progress spawn SetProgress(value=0.35);
    bar_line = render_progress(progress.value, 24);

    header = "Jackal │ OSP complex demo │ rev=" + str(session.graph_revision);
    status = (
        "phase="
        + shell.status.phase
        + " │ "
        + bar_line
        + " │ tool:jac_check"
    );
    prompt_lines = ["> ", "(draft empty after submit)"];
    _paint_shell(
        renderer,
        shell,
        header,
        win.lines if win.lines else ["(empty transcript)"],
        status,
        prompt_lines,
    );
    request_cursor(renderer, shell.prompt, row_offset=0, col_offset=2);

    frame1 = render_frame(renderer, shell.screen, term);
    demo.cells_written_total += frame1.cells_written;
    demo.frames_rendered += 1;
    cells1 = term.capture_cells();
    demo.last_frame = _frame_text(cells1);
    _step(
        demo,
        "frame_boot",
        "Jackal" in "".join(cells1) and frame1.sync_wrapped == True,
        "cells=" + str(frame1.cells_written),
    );
    _step(
        demo,
        "no_full_clear_boot",
        frame1.used_full_clear == False
        and frame_used_full_clear(term.writes) == False,
        "retained damage path",
    );

    # Mid-stream resize + more assistant content.
    shell_resize(session, shell, 100, 30);
    term.inject_resize(100, 30);
    renderer = create_renderer(100, 30);
    _install_shell_layout(renderer, shell, 100, 30);
    proj.viewport_width = 98;
    proj.viewport_height = 24;
    streamed2 = list(offscreen);
    streamed2.append(
        TranscriptMessage(
            message_id="m3",
            content="assistant: resize preserved shell node ids; rewrapping…",
            content_rev=1,
        )
    );
    apply_transcript_revision(proj, 4, streamed2);
    win2 = materialize_visible(proj);
    progress spawn SetProgress(value=0.8);
    bar_line = render_progress(progress.value, 24);
    shell.status.phase = "tool";
    _paint_shell(
        renderer,
        shell,
        "Jackal │ resized 100×30 │ rev=" + str(session.graph_revision),
        win2.lines if win2.lines else ["(empty)"],
        "phase=tool │ " + bar_line + " │ awaiting approval",
        ["> ", ""],
    );
    frame2 = render_frame(renderer, shell.screen, term);
    demo.cells_written_total += frame2.cells_written;
    demo.frames_rendered += 1;
    ids1 = shell_ids(shell);
    stable = (
        ids0.screen_id == ids1.screen_id
        and ids0.transcript_id == ids1.transcript_id
        and ids0.prompt_id == ids1.prompt_id
        and ids0.status_id == ids1.status_id
        and ids0.header_id == ids1.header_id
    );
    demo.stable_ids = stable;
    _step(demo, "resize_stable_ids", stable, "shell jids unchanged");

    open_res = shell_open_approval(session, shell);
    _step(
        demo,
        "approval_open",
        open_res.overlay_id != "" and session.focus_id == open_res.initial_focus_id,
        "overlay=" + open_res.overlay_id[:8],
    );
    _paint_shell(
        renderer,
        shell,
        "Jackal │ approval modal │ rev=" + str(session.graph_revision),
        win2.lines if win2.lines else ["(empty)"],
        "phase=approval │ " + bar_line,
        ["> ", ""],
        overlay_lines=[
            "┌─ Approve tool ─────────────────────────┐",
            "│ jac_check app/ui/renderer.jac          │",
            "│ [a] accept   [r] reject   [esc] cancel │",
            "└────────────────────────────────────────┘",
        ],
    );
    frame3 = render_frame(renderer, shell.screen, term);
    demo.cells_written_total += frame3.cells_written;
    demo.frames_rendered += 1;
    cells3 = term.capture_cells();
    demo.last_frame = _frame_text(cells3);
    joined3 = "".join(cells3);
    _step(
        demo,
        "approval_paint",
        "Approve tool" in joined3 and "jac_check" in joined3,
        "cells=" + str(frame3.cells_written),
    );

    close_res = shell_close_approval(session, shell);
    _step(
        demo,
        "approval_close",
        shell.approval is None and close_res.overlay_id != "",
        "restored_focus=" + close_res.restored_focus_id[:8],
    );

    cancel_turn(adapter, turn_id);
    cancel_env = dequeue(adapter.queue);
    _step(
        demo,
        "turn_cancel",
        cancel_env is not None and cancel_env.kind == "turn_cancelled",
        "correlation=" + turn_id,
    );
    shell.status.phase = "ready";

    findings = validate_invariants(session);
    demo.invariant_findings = len(findings);
    detail_findings = "";
    if findings {
        detail_findings = findings[0].kind + ": " + findings[0].detail;
    }
    _step(
        demo,
        "invariants",
        findings == [],
        detail_findings if detail_findings else "clean",
    );

    demo.graph_dump = dump_graph(session);
    demo.binding_dump = dump_bindings(session);
    life = dump_lifetimes(session, shell.prompt);
    _step(
        demo,
        "inspect_dumps",
        "MainScreen" in demo.graph_dump or "main" in demo.graph_dump,
        "graph_chars=" + str(len(demo.graph_dump)),
    );
    _step(
        demo,
        "lifetime_prompt",
        "prompt" in life or node_id(shell.prompt)[:8] in life,
        "cursor capability present",
    );

    leaked = ui_jids_reachable_from_persistent_root(set(session.tracked_node_ids));
    _step(
        demo,
        "detached_from_root",
        leaked == [],
        "leaked=" + str(len(leaked)),
    );

    term.stop();
    dispose_session(session);
    clean = (
        session.disposed
        and is_empty(session.bindings)
        and not session.tracked_node_ids
        and session.ui_root is None
        and not session.capabilities.by_node
    );
    demo.disposed_clean = clean;
    _step(demo, "dispose_clean", clean, "registries emptied");

    demo.latency_ms = (perf_counter() - t0) * 1000.0;
    if verbose {
        print(format_demo_report(demo));
    }
    return demo;
}


"""Pretty-print a demo result for `jac run`."""
def format_demo_report(demo: DemoReport) -> str {
    lines: list[str] = [];
    lines.append("=== OSP UI complex shell demo ===");
    lines.append(
        "result: "
        + ("PASS" if demo.passed else "FAIL")
        + "  frames="
        + str(demo.frames_rendered)
        + "  cells_written="
        + str(demo.cells_written_total)
        + "  coalesced="
        + str(demo.coalesced_deltas)
        + "  latency_ms="
        + str(round(demo.latency_ms, 2))
    );
    lines.append("stable_ids=" + str(demo.stable_ids)
        + "  disposed_clean=" + str(demo.disposed_clean)
        + "  invariant_findings=" + str(demo.invariant_findings));
    lines.append("");
    lines.append("-- steps --");
    for step in demo.steps {
        mark = "ok" if step.ok else "FAIL";
        extra = ("  " + step.detail) if step.detail else "";
        lines.append("  [" + mark + "] " + step.name + extra);
    }
    if demo.last_frame {
        lines.append("");
        lines.append("-- last virtual frame --");
        lines.append(demo.last_frame);
    }
    if demo.binding_dump {
        lines.append("");
        lines.append("-- bindings --");
        lines.append(demo.binding_dump);
    }
    return "\n".join(lines);
}


with entry {
    demo = run_complex_shell_demo(verbose=False);
    print(format_demo_report(demo));
    if not demo.passed {
        failed = [s.name for s in demo.steps if not s.ok];
        raise SystemExit("demo failed: " + ", ".join(failed));
    }
}
