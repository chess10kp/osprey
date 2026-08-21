"""Smoke: overlay selection updates redraw in place (no large cursor jumps).

Run: jac run smoke_overlay_inplace.jac
"""

import from src.tui { TUI }
import from src.terminal { ProcessTerminal }
import from src.terminal_support { process }
import from src.components.text { Text }
import from src.components.input { Input }
import from src.components.spacer { Spacer }
import from src.components.select_list { SelectList }
import from demo_support { drain_cooperative, feed_stdin }

glob ESC = chr(27);

obj SelectTheme {
    def selectedPrefix(text: str) -> str { return text; }
    def selectedText(text: str) -> str { return f"[{text}]"; }
    def description(text: str) -> str { return text; }
    def scrollInfo(text: str) -> str { return text; }
    def noMatch(text: str) -> str { return text; }
}

def largest_cursor_jump(data: str) -> int {
    import from re { findall }
    jumps: list[int] = [];
    for match_j in findall(r"\x1b\[(\d+(?:\.\d+)?)([AB])", data) {
        jumps.append(int(float(match_j[0])));
    }
    return max(jumps) if jumps else 0;
}

def count_picker_labels(output: str, label: str) -> int {
    import from re { sub }
    plain = sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", output);
    return plain.count(label);
}

with entry {
    process.stdout.capture = True;
    process.stdout.captured = [];

    term = ProcessTerminal();
    tui = TUI(term);
    log = Text(text="log area", paddingX=0, paddingY=0);
    inp = Input();
    tui.addChild(log);
    tui.addChild(Spacer(lines=18));
    tui.addChild(inp);
    tui.setFocus(inp);

    picker = SelectList(
        [
            {"value": "a", "label": "Alpha", "description": "first"},
            {"value": "b", "label": "Beta", "description": "second"},
            {"value": "c", "label": "Gamma", "description": "third"},
        ],
        5.0,
        SelectTheme(),
        {},
    );
    overlayHandle: dict = {};
    picker.onSelect = lambda (item: any) -> None {
        hide = overlayHandle.get("hide", None);
        if hide is not None {
            hide();
        }
        tui.setFocus(inp);
    };
    picker.onCancel = lambda () -> None {
        hide = overlayHandle.get("hide", None);
        if hide is not None {
            hide();
        }
        tui.setFocus(inp);
    };
    overlayHandle = tui.showOverlay(picker, {"row": 2.0, "col": "50%", "width": "70%"});

    tui.start();
    feed_stdin(f"{ESC}[?7u");
    drain_cooperative();
    process.stdout.captured = [];

    feed_stdin(f"{ESC}[B");
    drain_cooperative();
    process.stdout.captured = [];

    feed_stdin(f"{ESC}[B");
    drain_cooperative();

    output = "".join(process.stdout.captured);
    jump = largest_cursor_jump(output);
    assert jump <= 3, f"overlay nav cursor jump too large: {jump} in {output!r}";
    assert count_picker_labels(output, "Alpha") <= 2, f"overlay redraw duplicated rows: {output!r}";
    assert count_picker_labels(output, "Beta") <= 2, f"overlay redraw duplicated rows: {output!r}";
    assert count_picker_labels(output, "Gamma") <= 2, f"overlay redraw duplicated rows: {output!r}";

    tui.stop();
    process.stdout.capture = False;
    print("smoke_overlay_inplace OK");
}
