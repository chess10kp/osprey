"""Smoke: demo_playground /pick path via Input submit.

Run: jac run smoke_demo_picker.jac
"""

import from src.tui { TUI }
import from src.terminal { ProcessTerminal }
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

obj State {
    has log: any = None;
    has input: any = None;
    has tui: any = None;
    has hideOverlay: any | None = None;
    has picked: str = "";
}

def open_picker(state: State) -> None {
    if state.hideOverlay is not None {
        hideFn = state.hideOverlay.get("hide", None);
        if hideFn is not None {
            hideFn();
        }
        state.hideOverlay = None;
    }
    picker = SelectList(
        [
            {"value": "jackal", "label": "Jackal", "description": "agent"},
            {"value": "pi-tui", "label": "pi-tui", "description": "tui"},
        ],
        5.0,
        SelectTheme(),
        {},
    );
    picker.onSelect = lambda (item: any) -> None {
        state.picked = item.get("label", "?");
        hideFn = state.hideOverlay.get("hide", None);
        if hideFn is not None {
            hideFn();
        }
        state.hideOverlay = None;
        state.tui.setFocus(state.input);
    };
    picker.onCancel = lambda () -> None {
        state.picked = "cancelled";
        hideFn = state.hideOverlay.get("hide", None);
        if hideFn is not None {
            hideFn();
        }
        state.hideOverlay = None;
        state.tui.setFocus(state.input);
    };
    state.hideOverlay = state.tui.showOverlay(picker);
}

def on_submit(state: State, value: str) -> None {
    if value.strip().lower() == "/pick" {
        open_picker(state);
    }
    state.input.setValue("");
    state.tui.requestRender();
}

with entry {
    term = ProcessTerminal();
    tui = TUI(term);
    state = State();
    state.tui = tui;
    state.log = Text(text="log", paddingX=0, paddingY=0);
    state.input = Input();
    tui.addChild(state.log);
    tui.addChild(Spacer(lines=10));
    tui.addChild(state.input);
    tui.setFocus(state.input);
    state.input.onSubmit = lambda (value: str) -> None { on_submit(state, value); };

    tui.start();
    feed_stdin(f"{ESC}[?7u");
    drain_cooperative();

    feed_stdin("/pick\r");
    drain_cooperative();

    assert state.hideOverlay is not None, "overlay should open";
    assert len(tui.overlayStack) == 1;
    picker = tui.overlayStack[0].component;
    assert tui.focusedComponent == picker, f"focus={tui.focusedComponent}";

    feed_stdin(f"{ESC}[B");
    drain_cooperative();
    assert picker.selectedIndex == 1;

    # Kitty flags=7 emits release events; must not crash or steal focus.
    feed_stdin(f"{ESC}[57420:3u");
    drain_cooperative();
    assert picker.selectedIndex == 1;
    assert tui.focusedComponent == picker;

    feed_stdin("\r");
    drain_cooperative();

    assert state.picked == "pi-tui", f"picked={state.picked!r}";
    assert tui.focusedComponent == state.input;
    assert len(tui.overlayStack) == 0;

    tui.stop();
    print("smoke_demo_picker OK");
}
