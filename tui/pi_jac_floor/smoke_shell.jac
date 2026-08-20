"""End-to-end shell wiring smoke: Terminal -> StdinBuffer -> TUI -> focused Input.

Proves the real integration path under jac run (not unit-style direct calls):
ProcessTerminal.start wires stdin through StdinBuffer into TUI.handleInput,
focused Input receives key sequences, requestRender schedules cooperative
timers, and doRender paints captured stdout with cursor marker placement.

Run: jac check smoke_shell.jac && jac run smoke_shell.jac
"""

import from src.tui { TUI, CURSOR_MARKER }
import from src.terminal { ProcessTerminal }
import from src.terminal_support { process }
import from src.input_support { run_pending_timers, pending_timer_count }
import from src.components.input { Input }

glob ESC = chr(27);

def drain_cooperative(max_rounds: int = 16) -> None {
    rounds: int = 0;
    while (rounds < max_rounds) and (pending_timer_count() > 0) {
        run_pending_timers();
        rounds += 1;
    }
}

def captured_text() -> str {
    return "".join(process.stdout.captured);
}

with entry {
    process.stdout.capture = True;
    process.stdout.captured = [];

    term = ProcessTerminal();
    tui = TUI(term);
    inp = Input();
    tui.addChild(inp);
    tui.setFocus(inp);

    tui.start();

    # Terminal startup negotiates kitty keyboard protocol; consume the reply.
    process.stdin.feed(f"{ESC}[?7u");
    drain_cooperative();

    # Initial requestRender() from start() should paint the empty prompt.
    assert len(tui.previousLines) > 0;
    initialJoined = "\n".join(tui.previousLines);
    assert ">" in initialJoined;
    # doRender() strips CURSOR_MARKER while positioning the hardware cursor.
    assert CURSOR_MARKER not in initialJoined;
    assert f"{ESC}[7m" in initialJoined;

    # --- type through stdin -> StdinBuffer -> TUI -> Input ---
    process.stdout.captured = [];
    process.stdin.feed("hi");
    drain_cooperative();

    assert inp.getValue() == "hi";
    assert inp.cursor == 2;
    assert inp.focused;

    joined = "\n".join(tui.previousLines);
    assert "hi" in joined;
    assert f"{ESC}[7m" in joined;

    # --- arrow-left moves cursor; render reflects new position ---
    process.stdin.feed(f"{ESC}[D");
    drain_cooperative();

    assert inp.getValue() == "hi";
    assert inp.cursor == 1;
    joined = "\n".join(tui.previousLines);
    assert "> h" in joined;
    assert f"{ESC}[7mi{ESC}[27m" in joined;

    # --- insert at cursor via pipeline ---
    process.stdin.feed("!");
    drain_cooperative();

    assert inp.getValue() == "h!i";
    assert inp.cursor == 2;
    joined = "\n".join(tui.previousLines);
    assert "h!" in joined;
    assert f"{ESC}[7mi{ESC}[27m" in joined;

    # Render output should have reached captured stdout (not just previousLines).
    out = captured_text();
    assert len(out) > 0;
    assert "h!i" in inp.getValue();

    tui.stop();
    process.stdout.capture = False;

    print("smoke_shell OK (terminal/stdin/tui/input/render loop)");
}
