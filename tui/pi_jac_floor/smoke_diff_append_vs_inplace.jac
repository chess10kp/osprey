"""Smoke: differential render distinguishes in-place repaint vs bottom append.

Run: jac run smoke_diff_append_vs_inplace.jac
"""

import from src.tui { TUI, Container }
import from src.terminal { ProcessTerminal }
import from src.terminal_support { process }
import from src.components.text { Text }

obj LineComponent {
    has lines: list[str] = [];
    def setLines(lines: list[str]) -> None {
        self.lines = lines;
    }
    def render(width: float) -> list[str] {
        return list(self.lines);
    }
    def invalidate() -> None {}
    def handleInput(_data: str) -> None {}
}

with entry {
    process.stdout.capture = True;
    term = ProcessTerminal();
    tui = TUI(term);
    comp = LineComponent();
    tui.addChild(comp);

    comp.setLines(["Line 0", "Line 1", "Line 2"]);
    tui.doRender();
    assert len(tui.previousLines) == 3;

    # In-place: change middle line only
    process.stdout.captured = [];
    comp.setLines(["Line 0", "CHANGED", "Line 2"]);
    tui.doRender();
    inplaceBuf = "".join(process.stdout.captured);
    assert "[2K" in inplaceBuf, f"in-place should clear line: {inplaceBuf!r}";
    assert inplaceBuf.count("[2K") == 1, f"in-place should touch one line: {inplaceBuf!r}";
    # In-place path uses carriage return, not newline-before-write at changed row
    assert "\\r\\n" not in repr(inplaceBuf[:20]) or inplaceBuf.find("\r\n") > inplaceBuf.find("[2K"), (
        f"in-place should not prepend append-style newline: {inplaceBuf!r}"
    );

    # Append: add line at bottom without changing existing
    process.stdout.captured = [];
    comp.setLines(["Line 0", "CHANGED", "Line 2", "Line 3"]);
    tui.doRender();
    appendBuf = "".join(process.stdout.captured);
    assert "Line 3" in appendBuf or len(appendBuf) > 0, f"append should write new line: {appendBuf!r}";
    # Append path should use \r\n to step to new line from end of previous content
    assert "\r\n" in appendBuf, f"append should emit CRLF to new line: {appendBuf!r}";

    tui.stop();
    process.stdout.capture = False;
    print("smoke_diff_append_vs_inplace OK");

}
