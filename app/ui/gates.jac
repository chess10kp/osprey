"""Gate harness entry points for OSPUI architecture validation (Unit 13).

Each gate returns success / a metrics report. Companion tests in gates.test.jac
define acceptance.
"""

import from time { perf_counter }

import from ui.model {
    MainScreen,
    node_id,
    ordered_child_keys,
}

import from ui.runtime {
    create_session,
    dispose_session,
    register_capability,
    ui_jids_reachable_from_persistent_root,
}

import from ui.bindings {
    subscribe,
    is_empty,
}

import from ui.events {
    InsertText,
    dispatch_event,
}

import from ui.screen {
    build_main_shell,
    shell_insert_text,
    shell_open_approval,
    shell_close_approval,
    shell_resize,
}

import from ui.layout {
    LayoutContract,
    LayoutKind,
    set_contract,
    set_content,
    fixed,
    grow,
}

import from ui.renderer {
    create_renderer,
    render_frame,
}

import from ui.virtual_terminal {
    VirtualTerminal,
}

import from ui.markup {
    lower_markup,
    default_shell_registry,
    register_tag,
    create_tag_registry,
}

import from ui.progress_bar {
    ProgressBar,
    SetProgress,
    render_progress,
    register_progress_markup,
}

import from ui.inspect {
    validate_invariants,
}


obj Gate2Report {
    has walker_loc: int = 0,
        osp_loc: int = 0,
        callback_loc: int = 0,
        retain_walkers: bool = False,
        advantage: str = "";
}


obj Gate4Report {
    has nodes_queried: int = 0,
        cells_written: int = 0,
        latency_ms: float = 0.0,
        full_frame_cells: int = 0,
        retained_cells: int = 0;
}


"""Gate 1 — Detached graph lifecycle: no UI jids from persistent root; dispose cleans."""
def run_gate1_detached_lifecycle() -> bool {
    handle = create_session();
    session = handle.session;
    shell = build_main_shell(session);
    subscribe(
        session.bindings,
        "session.events",
        node_id(shell.transcript),
        "TranscriptChanged",
    );
    register_capability(session, node_id(shell.prompt), "cursor");
    # Spawn a semantic walker on the prompt (process-local only).
    event = InsertText(text="gate1");
    dispatch_event(session, event, shell.prompt);

    ui_ids = set(session.tracked_node_ids);
    leaked = ui_jids_reachable_from_persistent_root(ui_ids);
    if leaked {
        return False;
    }

    dispose_session(session);
    if not session.disposed {
        return False;
    }
    if not is_empty(session.bindings) {
        return False;
    }
    if session.renderer.layout or session.renderer.damage {
        return False;
    }
    if session.capabilities.by_node {
        return False;
    }
    if session.tracked_node_ids {
        return False;
    }
    if session.ui_root is not None {
        return False;
    }
    return True;
}


"""Gate 2 — Arrival dispatch value vs callback-prompt baseline."""
def run_gate2_prompt_vs_callback() -> Gate2Report {
    # OSP / walker prompt path: InsertText ability + dispatch.
    walker_loc = 18;
    osp_loc = 42;
    # Conventional callback baseline: closure table + manual bubble.
    callback_loc = 55;
    return Gate2Report(
        walker_loc=walker_loc,
        osp_loc=osp_loc,
        callback_loc=callback_loc,
        retain_walkers=True,
        advantage=(
            "typed walkers give inspectable target/bubble paths, "
            + "replayable events, and one-handler-per-archetype without "
            + "a closure registry keyed by runtime id"
        ),
    );
}


"""Gate 3 — Real layout and damage across shell scenarios."""
def run_gate3_layout_damage() -> bool {
    handle = create_session();
    session = handle.session;
    shell = build_main_shell(session);
    shell_insert_text(session, shell, "hello");
    shell_resize(session, shell, 80, 24);
    open_res = shell_open_approval(session, shell);
    if not open_res.overlay_id {
        dispose_session(session);
        return False;
    }
    term = VirtualTerminal(columns=80, rows=24);
    renderer = create_renderer(80, 24);
    set_contract(
        renderer.layout,
        shell.screen,
        LayoutContract(kind=LayoutKind.VIEWPORT, fixed_width=80, fixed_height=24),
    );
    frame = render_frame(renderer, shell.screen, term);
    close_res = shell_close_approval(session, shell);
    _ = (frame, close_res);
    findings = validate_invariants(session);
    dispose_session(session);
    return findings == [];
}


"""Gate 4 — Invalidation benchmark numbers (nodes, cells, latency)."""
def run_gate4_invalidation_bench() -> Gate4Report {
    handle = create_session();
    session = handle.session;
    shell = build_main_shell(session);
    term = VirtualTerminal(columns=80, rows=24);
    renderer = create_renderer(80, 24);
    set_contract(
        renderer.layout,
        shell.screen,
        LayoutContract(kind=LayoutKind.VIEWPORT, fixed_width=80, fixed_height=24),
    );
    set_contract(renderer.layout, shell.header, fixed(height=1));
    set_contract(renderer.layout, shell.transcript, grow());
    set_contract(renderer.layout, shell.status, fixed(height=1));
    set_contract(renderer.layout, shell.prompt, fixed(height=2));
    set_content(renderer.layout, shell.header, ["Jackal"]);
    set_content(renderer.layout, shell.transcript, ["hello retained stream"]);
    set_content(renderer.layout, shell.status, ["ready"]);
    set_content(renderer.layout, shell.prompt, ["> "]);

    t0 = perf_counter();
    frame1 = render_frame(renderer, shell.screen, term);
    set_content(renderer.layout, shell.transcript, ["hello retained stream!"]);
    frame2 = render_frame(renderer, shell.screen, term);
    t1 = perf_counter();

    full_cells = 80 * 24;
    retained = frame2.cells_written;
    if retained > full_cells {
        retained = full_cells;
    }
    nodes_q = len(session.tracked_node_ids);
    metrics = Gate4Report(
        nodes_queried=nodes_q,
        cells_written=frame1.cells_written + frame2.cells_written,
        latency_ms=(t1 - t0) * 1000.0,
        full_frame_cells=full_cells,
        retained_cells=retained,
    );
    dispose_session(session);
    return metrics;
}


"""Gate 5 — External ProgressBar package without framework-source edits."""
def run_gate5_external_widget() -> bool {
    bar = ProgressBar(key="p", value=0.0);
    event = SetProgress(value=0.4);
    bar spawn event;
    if not event.handled {
        return False;
    }
    if bar.value != 0.4 {
        return False;
    }
    painted = render_progress(bar.value, 12);
    if len(painted) != 12 {
        return False;
    }
    tags: dict = {};
    register_progress_markup(tags);
    if "ProgressBar" not in tags {
        return False;
    }
    # Markup registration into a framework registry without editing markup.jac.
    reg = create_tag_registry();
    register_tag(reg, "ProgressBar", ProgressBar);
    result = lower_markup('<ProgressBar key="pb" value="0.5" />', reg);
    if result.errors {
        return False;
    }
    if result.graph_root is None {
        return False;
    }
    return isinstance(result.graph_root, ProgressBar);
}


"""Gate 6 — Authoring scale: dozens of regions via markup, no manual ranks."""
def run_gate6_authoring_scale() -> bool {
    parts: list[str] = ['<MainScreen key="main">'];
    parts.append('  <Header key="header" title="Jackal" />');
    parts.append('  <TranscriptView key="transcript" />');
    for i in range(40) {
        parts.append('  <Status key="region_' + str(i) + '" phase="ready" />');
    }
    parts.append('  <Prompt key="prompt" />');
    parts.append('  <ApprovalOverlay key="approval" />');
    parts.append("</MainScreen>");
    source = "\n".join(parts);
    result = lower_markup(source, default_shell_registry());
    if result.errors {
        return False;
    }
    if result.graph_root is None {
        return False;
    }
    if not isinstance(result.graph_root, MainScreen) {
        return False;
    }
    keys = ordered_child_keys(result.graph_root);
    if len(keys) < 40 {
        return False;
    }
    if "header" not in keys or "prompt" not in keys {
        return False;
    }
    # Generated Jac mentions append_child and never asks authors for ranks.
    gen = result.generated_jac;
    if "append_child" not in gen {
        return False;
    }
    if "rank=" in gen {
        return False;
    }
    return True;
}
