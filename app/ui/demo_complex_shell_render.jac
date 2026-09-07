"""Layout and paint helpers for the headless complex shell demo."""

import from ui.layout_types {
    LayoutSpec,
    fill_axis,
    fixed_axis,
    grow_axis,
}

import from ui.renderer {
    Renderer,
    set_node_content,
    set_node_contract,
    mark_semantic_dirty,
    mark_layout_dirty,
}

import from ui.screen { ShellScreen }


def _install_shell_layout(renderer: Renderer, shell: ShellScreen, columns: int, rows: int) {
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
    renderer: Renderer,
    shell: ShellScreen,
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
