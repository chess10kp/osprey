"""Smoke: demo-style picker overlay — navigation should not duplicate rows.

Run: jac run smoke_picker_navigation.jac
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

def count_label(output: str, label: str) -> int {
    import from re { sub }
    plain = sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", output);
    return plain.count(label);
}

with entry {
    process.stdout.capture = True;
    process.stdout.captured = [];

    term = ProcessTerminal();
    tui = TUI(term);
    tui.setClearOnShrink(True);
    header = Text(text=" pi-tui playground ", paddingX=0, paddingY=0);
    log = Text(text="welcome", paddingX=1, paddingY=0);
    status = Text(text="status", paddingX=0, paddingY=0);
    filler = Spacer(lines=18.0);
    inp = Input();
    tui.addChild(header);
    tui.addChild(log);
    tui.addChild(status);
    tui.addChild(filler);
    tui.addChild(inp);
    tui.setFocus(inp);

    picker = SelectList(
        [
            {"value": "jackal", "label": "Jackal", "description": "Jac-native coding agent"},
            {"value": "pi-tui", "label": "pi-tui", "description": "Terminal UI framework (this port)"},
            {"value": "jac", "label": "Jac", "description": "Programming language + runtime"},
        ],
        5.0,
        SelectTheme(),
        {},
    );
    tui.showOverlay(picker);

    tui.start();
    feed_stdin(f"{ESC}[?7u");
    drain_cooperative();
    process.stdout.captured = [];

    i: int = 0;
    while (i < 4) {
        feed_stdin(f"{ESC}[B");
        drain_cooperative();
        out = "".join(process.stdout.captured);
        process.stdout.captured = [];
        assert count_label(out, "Jackal") <= 2, f"dup Jackal on nav {i}: {out!r}";
        assert count_label(out, "pi-tui") <= 2, f"dup pi-tui on nav {i}: {out!r}";
        i += 1;
    }

    tui.stop();
    process.stdout.capture = False;
    print("smoke_picker_navigation OK");
}
