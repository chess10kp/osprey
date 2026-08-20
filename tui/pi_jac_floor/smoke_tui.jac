"""Runtime smoke for the TUI render/reconcile engine (tui.jac).

tui.jac is the keystone module -- input.jac, settings_list.jac, and index.jac
all transitively depend on it (input.jac imports CURSOR_MARKER from it). This
smoke proves the module imports cleanly under the Jac runtime and exercises
its core render/diff path with real components and a captured-stdout
terminal: first render (full paint), an unchanged re-render (no-op diff),
and a changed re-render (line-scoped redraw), plus the numeric width/row math
and dict-based line records used throughout doRender/compositeOverlays.

Run: jac run smoke_tui.jac
"""

import from src.tui { TUI, Container, CURSOR_MARKER, parseSizeValue, isFocusable }
import from src.terminal { ProcessTerminal }
import from src.terminal_support { process }
import from src.components.text { Text }

with entry {
    # --- CURSOR_MARKER: the constant input.jac needs from this module ---
    if (not isinstance(CURSOR_MARKER, str)) or (len(CURSOR_MARKER) == 0) {
        raise Exception("CURSOR_MARKER must be a non-empty str");
    }

    # --- pure helpers exercised directly ---
    if parseSizeValue(None, 100.0) is not None {
        raise Exception("parseSizeValue(None, ...) should be None");
    }
    if parseSizeValue("50%", 100.0) != 50 {
        raise Exception("parseSizeValue('50%', 100) should be 50");
    }
    if parseSizeValue(12, 100.0) != 12 {
        raise Exception("parseSizeValue(12, ...) should pass through numbers");
    }
    if isFocusable(None) != False {
        raise Exception("isFocusable(None) should be False");
    }
    if isFocusable({"focused": False}) != True {
        raise Exception("isFocusable(dict with 'focused' key) should be True");
    }

    # --- headless terminal, stdout captured instead of written for real ---
    process.stdout.capture = True;
    process.stdout.captured = [];
    term = ProcessTerminal();

    tui = TUI(term);
    if tui.children != [] {
        raise Exception("TUI() should start with no children (base default seeded)");
    }

    text = Text(text="hello", paddingX=1, paddingY=0);
    tui.addChild(text);

    width = int(term.columns());
    height = int(term.rows());

    # --- first render: previousLines empty -> full repaint path ---
    tui.doRender();
    if len(tui.previousLines) == 0 {
        raise Exception("first doRender() should have produced lines");
    }
    firstJoined = "\n".join(tui.previousLines);
    if "hello" not in firstJoined {
        raise Exception("rendered output should contain the Text content");
    }
    if tui.fullRedraws() != 1 {
        raise Exception(f"expected exactly 1 full redraw after first render, got {tui.fullRedraws()}");
    }
    firstCaptured = list(process.stdout.captured);
    if len(firstCaptured) == 0 {
        raise Exception("first render should have written to the terminal");
    }

    # --- unchanged re-render: identical frame -> no additional write ---
    process.stdout.captured = [];
    savedPreviousLines = list(tui.previousLines);
    tui.doRender();
    if tui.previousLines != savedPreviousLines {
        raise Exception("re-rendering identical content should not change previousLines");
    }
    # No changed lines: doRender still repositions the (hidden) hardware
    # cursor, but must not clear/rewrite any content line.
    unchangedBuffer = "".join(process.stdout.captured);
    if ("[2K" in unchangedBuffer) or ("hello" in unchangedBuffer) {
        raise Exception("re-rendering identical content should not redraw any line");
    }
    if tui.fullRedraws() != 1 {
        raise Exception("unchanged re-render must not trigger another full redraw");
    }

    # --- changed re-render: mutate the leaf, expect a scoped (non-full) redraw ---
    text.text = "goodbye";
    process.stdout.captured = [];
    tui.doRender();
    changedJoined = "\n".join(tui.previousLines);
    if "goodbye" not in changedJoined {
        raise Exception("changed re-render should reflect the new text");
    }
    if "hello" in changedJoined {
        raise Exception("changed re-render should not still show the old text");
    }
    if len(process.stdout.captured) == 0 {
        raise Exception("changed re-render should have written an update");
    }
    if tui.fullRedraws() != 1 {
        raise Exception(f"line-scoped diff should not trigger a full redraw, got {tui.fullRedraws()} full redraws");
    }
    # A scoped redraw clears+rewrites the changed line(s), not the whole screen:
    # it must not contain the "clear scrollback" full-redraw sequence.
    changedBuffer = "".join(process.stdout.captured);
    if "[2J" in changedBuffer {
        raise Exception("line-scoped redraw should not emit a full-screen clear");
    }
    if "[2K" not in changedBuffer {
        raise Exception("line-scoped redraw should emit a line-clear sequence");
    }

    # --- forced full re-render (e.g. terminal resize) does a full repaint again ---
    process.stdout.captured = [];
    tui.requestRender(True);
    if tui.fullRedraws() != 2 {
        raise Exception(f"forced render should trigger a second full redraw, got {tui.fullRedraws()}");
    }

    # --- width/row math: compositeLineAt and extractCursorPosition on raw frames ---
    base = "abcdefghij";
    overlay = "XY";
    composited = tui.compositeLineAt(base, overlay, 3.0, 2.0, 10.0);
    if len(composited) == 0 {
        raise Exception("compositeLineAt should return a non-empty composed line");
    }

    linesWithCursor = ["no cursor here", f"cursor{CURSOR_MARKER}here"];
    pos = tui.extractCursorPosition(linesWithCursor, 2.0);
    if pos is None {
        raise Exception("extractCursorPosition should find the embedded marker");
    }
    if pos["row"] != 1 {
        raise Exception(f"cursor marker is on line 1, got row={pos['row']}");
    }
    if pos["col"] != len("cursor") {
        raise Exception(f"cursor col should be after 'cursor', got {pos['col']}");
    }
    if CURSOR_MARKER in linesWithCursor[1] {
        raise Exception("extractCursorPosition should strip the marker from the line in place");
    }

    tui.stop();
    process.stdout.capture = False;

    print("smoke_tui OK (import / render / diff / forced-full-redraw / compositeLineAt / extractCursorPosition)");
}
