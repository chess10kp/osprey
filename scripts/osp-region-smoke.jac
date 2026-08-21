"""Runtime smoke: OSP region painter drives terminal output directly.

Run from the repository root with:
  JACPATH=app:tui/pi_jac_floor jac run scripts/osp-region-smoke.jac
"""

import from ui.model {
    UiNode, SignalNode, signal, read_signal, set_signal, own_signal,
    view, column, reset_ui_runtime, ui_runtime,
}
import from ui.paint { paint_frame }
import from src.terminal_support { process }


def signal_lines(source: SignalNode) -> any {
    def render(_node: UiNode, _width: int) -> list[str] {
        return [str(read_signal(source))];
    }
    return render;
}


def blank_lines(count: int) -> any {
    def render(_node: UiNode, _width: int) -> list[str] {
        lines: list[str] = [];
        i = 0;
        while i < count {
            lines.append("");
            i += 1;
        }
        return lines;
    }
    return render;
}


with entry {
    reset_ui_runtime();
    process.stdout.capture = True;
    process.stdout.captured = [];

    log_source = signal("log0");
    status_source = signal("idle");
    log_view = view(signal_lines(log_source), kind="log", key="log");
    spacer_view = view(blank_lines(3), kind="spacer", key="spacer");
    status_view = view(signal_lines(status_source), kind="status", key="status");
    root_view = column([log_view, spacer_view, status_view]);
    own_signal(root_view, log_source);
    own_signal(root_view, status_source);

    width = 80;
    paint_frame(root_view, width, process.stdout.write);
    assert log_view.screen_row == 0;
    assert spacer_view.screen_row == 1;
    assert status_view.screen_row == 4;
    process.stdout.captured = [];

    set_signal(status_source, "status");
    jobs = paint_frame(root_view, width, process.stdout.write);
    status_output = "".join(process.stdout.captured);
    assert len(jobs) == 1;
    assert jobs[0].key == "status";
    assert "\x1b[2K" in status_output;
    assert "status" in status_output;
    process.stdout.captured = [];

    def growing_log(_node: UiNode, _width: int) -> list[str] {
        return ["log0", "log1"];
    }
    ui_runtime().renderers[log_view.runtime_id] = growing_log;
    log_view.dirty = True;
    log_view.cached_width = -1;
    shift_jobs = paint_frame(root_view, width, process.stdout.write);
    shift_output = "".join(process.stdout.captured);
    shift_keys = [n.key for n in shift_jobs];
    assert shift_keys == ["log", "spacer", "status"];
    assert "\x1b[2K" in shift_output;
    assert spacer_view.screen_row == 2;
    assert status_view.screen_row == 5;

    process.stdout.capture = False;
    print("osp_region_smoke OK");
}
