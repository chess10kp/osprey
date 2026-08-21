"""Jackal shell topology: durable MainScreen under UiSessionRoot.

Builds the representative shell once and keeps semantic node IDs stable
across typing, streaming, resize, focus, and overlay cycles (OSPUI.md §17–18,
OSPUI-P0-PLAN Unit 8).
"""

import from ui.model {
    MainScreen,
    Header,
    TranscriptView,
    Status,
    Prompt,
    ApprovalOverlay,
    UiNode,
    node_id,
}

import from ui.runtime {
    UiSession,
    OverlayOpenResult,
    OverlayCloseResult,
    OverlayBounds,
    append_child_session,
    set_current_screen,
    set_focus,
    open_modal_overlay,
    close_overlay,
    track_node,
}

import from ui.events {
    SendPrompt,
}


obj ShellScreen {
    has screen: MainScreen,
        header: Header,
        transcript: TranscriptView,
        status: Status,
        prompt: Prompt,
        approval: ApprovalOverlay | None = None;
}


obj ShellIdSnapshot {
    has screen_id: str,
        header_id: str,
        transcript_id: str,
        status_id: str,
        prompt_id: str;
}


glob _SHELL_BY_SESSION: dict[str, ShellScreen] = {};


"""Build MainScreen(Header, TranscriptView, Status, Prompt) under ui_root once."""
def build_main_shell(session: UiSession) -> ShellScreen {
    if session.disposed or session.ui_root is None {
        raise ValueError("UiSession is disposed or missing ui_root");
    }
    root_id = node_id(session.ui_root);
    if root_id in _SHELL_BY_SESSION {
        existing = _SHELL_BY_SESSION[root_id];
        if session.current_screen is existing.screen {
            return existing;
        }
        raise ValueError("main shell already built for this session");
    }
    screen = MainScreen(key="main");
    header = Header(key="header", title="Jackal");
    transcript = TranscriptView(key="transcript");
    status = Status(key="status", phase="ready");
    prompt = Prompt(key="prompt");

    append_child_session(session, session.ui_root, screen);
    append_child_session(session, screen, header);
    append_child_session(session, screen, transcript);
    append_child_session(session, screen, status);
    append_child_session(session, screen, prompt);
    set_current_screen(session, screen);
    set_focus(session, prompt);

    shell = ShellScreen(
        screen=screen,
        header=header,
        transcript=transcript,
        status=status,
        prompt=prompt,
    );
    _SHELL_BY_SESSION[root_id] = shell;
    return shell;
}


"""Snapshot stable jids for shell regions (for stability assertions)."""
def shell_ids(shell: ShellScreen) -> ShellIdSnapshot {
    return ShellIdSnapshot(
        screen_id=node_id(shell.screen),
        header_id=node_id(shell.header),
        transcript_id=node_id(shell.transcript),
        status_id=node_id(shell.status),
        prompt_id=node_id(shell.prompt),
    );
}


"""Insert text into the focused prompt draft (multiline-aware)."""
def shell_insert_text(session: UiSession, shell: ShellScreen, text: str) {
    _ = session;
    shell.prompt.draft = shell.prompt.draft + text;
}


"""Submit the prompt draft; returns host effects (e.g. SendPrompt)."""
def shell_submit(session: UiSession, shell: ShellScreen) -> list[any] {
    _ = session;
    text = shell.prompt.draft;
    shell.prompt.draft = "";
    return [SendPrompt(text=text)];
}


"""Cancel in-progress edit / turn from the shell."""
def shell_cancel(session: UiSession, shell: ShellScreen) {
    _ = session;
    shell.prompt.draft = "";
}


"""Open the modal ApprovalOverlay for the shell."""
def shell_open_approval(
    session: UiSession,
    shell: ShellScreen,
) -> OverlayOpenResult {
    if shell.approval is not None {
        return open_modal_overlay(
            session, shell.screen, shell.approval, initial_focus=shell.approval
        );
    }
    approval = ApprovalOverlay(key="approval");
    append_child_session(session, shell.screen, approval);
    track_node(session, approval);
    shell.approval = approval;
    return open_modal_overlay(
        session, shell.screen, approval, initial_focus=approval, z_index=10
    );
}


"""Close the approval overlay and restore shell focus."""
def shell_close_approval(
    session: UiSession,
    shell: ShellScreen,
) -> OverlayCloseResult {
    if shell.approval is None {
        return OverlayCloseResult(
            restored_focus_id=session.focus_id,
            damage=OverlayBounds(),
            overlay_id="",
        );
    }
    approval = shell.approval;
    shell.approval = None;
    return close_overlay(session, approval);
}


"""Apply a terminal resize to shell layout contracts / content wrap."""
def shell_resize(
    session: UiSession,
    shell: ShellScreen,
    columns: int,
    rows: int,
) {
    _ = shell;
    if columns < 1 or rows < 1 {
        raise ValueError("resize requires positive columns and rows");
    }
    session.graph_revision += 1;
    session.event_queue.append(
        {
            "kind": "resize",
            "payload": {"columns": columns, "rows": rows},
        }
    );
}
