"""Smoke: SelectList overlay focus routing (/pick demo path).

Run: jac run smoke_picker_overlay.jac
"""

import from src.tui { TUI }
import from src.terminal { ProcessTerminal }
import from src.terminal_support { process }
import from src.components.text { Text }
import from src.components.input { Input }
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

with entry {
    process.stdout.capture = True;
    process.stdout.captured = [];

    term = ProcessTerminal();
    tui = TUI(term);
    log = Text(text="", paddingX=0, paddingY=0);
    inp = Input();
    tui.addChild(log);
    tui.addChild(inp);
    tui.setFocus(inp);

    picked: dict = {"value": ""};
    picker = SelectList(
        [
            {"value": "a", "label": "Alpha", "description": "first"},
            {"value": "b", "label": "Beta", "description": "second"},
        ],
        5.0,
        SelectTheme(),
        {},
    );
    picker.onSelect = lambda (item: any) -> None {
        picked["value"] = item.get("label", "?");
        hide = overlayHandle.get("hide", None);
        if hide is not None {
            hide();
        }
        tui.setFocus(inp);
    };
    picker.onCancel = lambda () -> None {
        picked["value"] = "cancelled";
        hide = overlayHandle.get("hide", None);
        if hide is not None {
            hide();
        }
        tui.setFocus(inp);
    };
    overlayHandle = tui.showOverlay(picker);

    tui.start();
    feed_stdin(f"{ESC}[?7u");
    drain_cooperative();
    tui.doRender();

    assert tui.focusedComponent == picker;

    feed_stdin(f"{ESC}[B");
    drain_cooperative();
    assert picker.selectedIndex == 1, f"selectedIndex={picker.selectedIndex}";

    feed_stdin("\r");
    drain_cooperative();

    assert picked["value"] == "Beta", f"picked={picked['value']!r} focus={tui.focusedComponent} overlays={len(tui.overlayStack)}";
    assert tui.focusedComponent == inp;
    assert len(tui.overlayStack) == 0;

    tui.stop();
    process.stdout.capture = False;
    print("smoke_picker_overlay OK");
}
