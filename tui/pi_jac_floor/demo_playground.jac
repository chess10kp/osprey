"""Interactive pi-tui playground — full-screen terminal UI demo.

Run from a real TTY:
  cd tui/pi_jac_floor && jac run demo_playground.jac

Headless / piped (scripted tour, no alternate screen):
  jac run demo_playground.jac < /dev/null

Controls:
  Type at the bottom prompt, Enter to submit.
  /help   — show commands
  /pick   — open a SelectList overlay (↑/↓, Enter, Esc)
  /clear  — wipe the log and redraw the full screen
  /quit   — exit (Ctrl+C also works)
"""

import from src.tui { TUI }
import from src.terminal { ProcessTerminal }
import from src.components.text { Text }
import from src.components.input { Input }
import from src.components.spacer { Spacer }
import from src.components.select_list { SelectList }
import from demo_support {
    clear_screen,
    drain_cooperative,
    enter_fullscreen,
    feed_stdin,
    leave_fullscreen,
    run_interactive,
    run_scripted,
    stdin_is_tty,
}

glob WELCOME = "Type /help for commands, or /pick for a menu overlay.";

obj SelectTheme {
    def selectedPrefix(text: str) -> str { return text; }
    def selectedText(text: str) -> str { return f"[{text}]"; }
    def description(text: str) -> str { return text; }
    def scrollInfo(text: str) -> str { return text; }
    def noMatch(text: str) -> str { return text; }
}

obj DemoState {
    has log: any = None;
    has input: any = None;
    has tui: any = None;
    has header: any = None;
    has status: any = None;
    has filler: any = None;
    has running: bool = True;
    has hideOverlay: any | None = None;
    has last_rows: int = 0;
    has last_cols: int = 0;
    has use_fullscreen: bool = False;
}

def count_render_lines(component: any, width: float) -> int {
    if component is None {
        return 0;
    }
    return len(component.render(width));
}

def update_layout(state: DemoState, force_render: bool = False) -> None {
    term = state.tui.terminal;
    rows = int(term.rows() or 24);
    cols = int(term.columns() or 80);
    width = float(cols);
    size_changed = ((rows != state.last_rows) or (cols != state.last_cols));
    if size_changed {
        state.last_rows = rows;
        state.last_cols = cols;
    }

    headerLines = count_render_lines(state.header, width);
    logLines = count_render_lines(state.log, width);
    statusLines = count_render_lines(state.status, width);
    inputLines = 1;
    used = (headerLines + logLines + statusLines + inputLines);
    fillerLines = max(0, rows - used);
    state.filler.setLines(float(fillerLines));

    state.status.setText(f"  {cols}x{rows}  |  /help  /pick  /clear  /quit");

    if force_render or size_changed {
        state.tui.requestRender(force=force_render);
    } else {
        state.tui.requestRender();
    }
}

def append_log(state: DemoState, line: str) -> None {
    prev = state.log.text;
    if (prev.strip() == "") or (prev == WELCOME) {
        newText = line;
    } else {
        newText = f"{prev}\n{line}";
    }
    lines = newText.split("\n");
    maxLog = max(3, state.last_rows - 6);
    if len(lines) > maxLog {
        lines = lines[-maxLog:];
        newText = "\n".join(lines);
    }
    state.log.setText(newText);
    update_layout(state);
}

def close_overlay(state: DemoState) -> None {
    if state.hideOverlay is not None {
        hideFn = state.hideOverlay.get("hide", None);
        if hideFn is not None {
            hideFn();
        }
        state.hideOverlay = None;
    }
}

def redraw_all(state: DemoState) -> None {
    clear_screen(state.tui.terminal);
    update_layout(state, force_render=True);
    drain_cooperative();
}

def open_picker(state: DemoState) -> None {
    close_overlay(state);
    update_layout(state);
    pickerItems: list[any] = [
        {"value": "jackal", "label": "Jackal", "description": "Jac-native coding agent"},
        {"value": "pi-tui", "label": "pi-tui", "description": "Terminal UI framework (this port)"},
        {"value": "jac", "label": "Jac", "description": "Programming language + runtime"},
    ];
    theme = SelectTheme();
    pickerLayout: dict = {};
    picker = SelectList(pickerItems, 5.0, theme, pickerLayout);
    picker.onSelect = lambda (item: any) -> None {
        label = item.get("label", item.get("value", "?"));
        close_overlay(state);
        append_log(state, f"picked: {label}");
        state.input.setValue("");
        state.tui.setFocus(state.input);
        update_layout(state);
    };
    picker.onCancel = lambda () -> None {
        close_overlay(state);
        append_log(state, "picker cancelled");
        state.tui.setFocus(state.input);
        update_layout(state);
    };
    state.hideOverlay = state.tui.showOverlay(
        picker,
        {"row": "25%", "col": "50%", "width": "80%", "maxHeight": 8.0},
    );
}

def handle_command(state: DemoState, text: str) -> None {
    cmd = text.strip();
    lower = cmd.lower();
    if lower == "/quit" or lower == "/exit" {
        state.running = False;
        return;
    }
    if lower == "/help" {
        append_log(
            state,
            "commands: /help /pick /clear /quit — editor keys work in the prompt",
        );
        return;
    }
    if lower == "/clear" {
        state.log.setText(WELCOME);
        redraw_all(state);
        return;
    }
    append_log(state, f"› {cmd}");
}

def on_submit(state: DemoState, value: str) -> None {
    if not value.strip() {
        return;
    }
    cmd = value.strip();
    lower = cmd.lower();
    state.input.setValue("");
    if lower == "/pick" {
        open_picker(state);
        return;
    }
    handle_command(state, cmd);
    if state.running {
        update_layout(state);
    }
}

def build_ui() -> DemoState {
    term = ProcessTerminal();
    tui = TUI(term);
    state = DemoState();
    state.tui = tui;
    state.use_fullscreen = stdin_is_tty();
    state.header = Text(text=" pi-tui playground ", paddingX=0, paddingY=0);
    state.log = Text(text=WELCOME, paddingX=1, paddingY=0);
    state.status = Text(text="", paddingX=0, paddingY=0);
    state.filler = Spacer(lines=1);
    state.input = Input();

    tui.addChild(state.header);
    tui.addChild(state.log);
    tui.addChild(state.status);
    tui.addChild(state.filler);
    tui.addChild(state.input);
    tui.setFocus(state.input);
    tui.setClearOnShrink(True);

    state.input.onSubmit = lambda (value: str) -> None { on_submit(state, value); };

    return state;
}

def should_continue(state: DemoState) -> bool {
    return state.running and (not state.tui.stopped);
}

def tick_layout(state: DemoState) -> None {
    rows = int(state.tui.terminal.rows() or 24);
    cols = int(state.tui.terminal.columns() or 80);
    if ((rows != state.last_rows) or (cols != state.last_cols)) {
        update_layout(state);
    }
}

with entry {
    state = build_ui();

    if state.use_fullscreen {
        enter_fullscreen(state.tui.terminal);
    }

    state.tui.start();
    drain_cooperative();
    update_layout(state, force_render=True);
    drain_cooperative();

    should_cont = lambda () -> bool { return should_continue(state); };
    tick_fn = lambda () -> None { tick_layout(state); };

    if state.use_fullscreen {
        run_interactive(should_cont, tick_fn);
    } else {
        run_scripted(
            [
                f"{chr(27)}[?7u",
                "/help\r",
                "hello pi-tui\r",
                "/clear\r",
                "/pick\r",
                f"{chr(27)}[B",
                "\r",
                "/quit\r",
            ],
            should_cont,
        );
    }

    close_overlay(state);
    state.tui.stop();

    if state.use_fullscreen {
        leave_fullscreen(state.tui.terminal);
    } else {
        print("demo_playground OK (scripted headless tour)");
    }
}
