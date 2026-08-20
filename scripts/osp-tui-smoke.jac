"""Runtime smoke: OSP model drives the existing differential TUI renderer.

Run from the repository root with:
  JACPATH=app:tui/pi_jac_floor jac run scripts/osp-tui-smoke.jac
"""

import from ui.model {
    UiNode, SignalNode, signal, read_signal, set_signal, own_signal,
    view, project, dispose_tree, reset_ui_runtime, set_render_request_hook
}
import from src.tui { TUI }
import from src.terminal { ProcessTerminal }
import from src.terminal_support { process }
import from src.input_support { run_pending_timers }


def signal_lines(source: SignalNode) -> any {
    def render(_node: UiNode, _width: int) -> list[str] {
        return [str(read_signal(source))];
    }
    return render;
}


with entry {
    reset_ui_runtime();
    process.stdout.capture = True;
    process.stdout.captured = [];

    source = signal("before");
    root_view = view(signal_lines(source), kind="transcript");
    own_signal(root_view, source);
    component = project(root_view);

    term = ProcessTerminal();
    tui = TUI(term);
    tui.addChild(component);
    set_render_request_hook(tui.requestRender);

    tui.doRender();
    assert tui.previousLines[0].startswith("before");
    process.stdout.captured = [];

    set_signal(source, "after");
    run_pending_timers();
    output = "".join(process.stdout.captured);
    assert tui.previousLines[0].startswith("after");
    assert "after" in output;
    assert "\x1b[2K" in output;

    dispose_tree(root_view);
    process.stdout.capture = False;
    print("osp_tui_smoke OK");
}
