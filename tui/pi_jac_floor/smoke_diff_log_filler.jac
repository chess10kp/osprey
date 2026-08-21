"""Smoke: log append with filler shrink must not use pure-append cursor path.

When a transcript grows but a spacer shrinks, total line count may stay constant.
The renderer must repaint changed rows in place, not assume bottom-append.

Run: jac run smoke_diff_log_filler.jac
"""

import from src.tui { TUI }
import from src.terminal { ProcessTerminal }
import from src.terminal_support { process }
import from src.components.text { Text }
import from src.components.spacer { Spacer }

with entry {
    process.stdout.capture = True;
    term = ProcessTerminal();
    tui = TUI(term);

    header = Text(text="HEADER", paddingX=0, paddingY=0);
    log = Text(text="log0", paddingX=0, paddingY=0);
    filler = Spacer(lines=10.0);
    status = Text(text="STATUS v0", paddingX=0, paddingY=0);
    tui.addChild(header);
    tui.addChild(log);
    tui.addChild(filler);
    tui.addChild(status);

    tui.doRender();
    prevCount = len(tui.previousLines);
    assert prevCount == 13;  # 1 + 1 + 10 + 1

    # Grow log by one line, shrink filler by one — same total height
    process.stdout.captured = [];
    log.setText("log0\nlog1");
    filler.setLines(9.0);
    tui.doRender();

    assert len(tui.previousLines) == prevCount, "line count unchanged when filler absorbs growth";
    buf = "".join(process.stdout.captured);
    assert "[2K" in buf, f"should redraw changed region: {buf!r}";
    assert ".0" not in buf, f"CSI params must be integers, not floats: {buf!r}";
    # Insertion shifted filler rows — must repaint through the tail, not a single-line touch.
    assert buf.count("[2K") >= 2, f"shifted insert should redraw tail rows: {buf!r}";

    # Status-only in-place update (single line change, count unchanged)
    process.stdout.captured = [];
    status.setText("STATUS v1");
    tui.doRender();
    statusBuf = "".join(process.stdout.captured);
    assert "[2K" in statusBuf, f"status repaint should clear its line: {statusBuf!r}";
    assert statusBuf.count("[2K") == 1, f"status should touch one line only: {statusBuf!r}";
    assert ".0" not in statusBuf, f"CSI params must be integers: {statusBuf!r}";
    assert tui.fullRedraws() == 1, "should stay on differential path";

    tui.stop();
    process.stdout.capture = False;
    print("smoke_diff_log_filler OK");

}
