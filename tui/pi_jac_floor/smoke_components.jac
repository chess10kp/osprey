"""Runtime smoke for display/list components: Loader, CancellableLoader,
TruncatedText, Spacer, terminal_colors, SelectList.

Proves converted components execute (not just check) under the Jac runtime,
exercising real behavior with assertions on known inputs/outputs. No
Node/terminal deps -- Loader's setInterval/clearInterval calls are backed by
the cooperative terminal_support timer queue (run_pending_intervals()).

Run: jac run smoke_components.jac
"""

import from src.utils { visibleWidth }
import from src.terminal_support { run_pending_intervals }
import from src.components.loader { Loader }
import from src.components.cancellable_loader { CancellableLoader }
import from src.components.truncated_text { TruncatedText }
import from src.components.spacer { Spacer }
import from src.terminal_colors { hexToRgb, isOsc11BackgroundColorResponse, parseOsc11BackgroundColor, parseTerminalColorSchemeReport }
import from src.components.select_list { SelectList }

def identity(s: str) -> str {
    return s;
}

obj Indicator {
    has frames: list[str] = ["A", "B", "C"];
    has intervalMs: float = 10;
}

obj SelectTheme {
    def selectedPrefix(text: str) -> str { return text; }
    def selectedText(text: str) -> str { return f"[{text}]"; }
    def description(text: str) -> str { return text; }
    def scrollInfo(text: str) -> str { return text; }
    def noMatch(text: str) -> str { return text; }
}

with entry {
    ESC = chr(27);

    # ---------------------------------------------------------------
    # Loader: construct, tick frames via cooperative interval, render.
    # ---------------------------------------------------------------
    ui_requested: list[bool] = [];
    obj FakeUi {
        def requestRender() -> None {
            ui_requested.append(True);
        }
    }
    fakeUi = FakeUi();
    loader = Loader(ui=fakeUi, spinnerColorFn=identity, messageColorFn=identity, message="Working");
    frame0 = "".join(loader.render(float(30)));
    assert "Working" in frame0;
    startFrame = loader.currentFrame;

    loader.start();
    assert len(ui_requested) >= 1;   # updateDisplay() called on start
    fired = run_pending_intervals();
    assert fired == 1;
    assert loader.currentFrame == ((startFrame + 1) % len(loader.frames));
    frame1 = "".join(loader.render(float(30)));
    # spinner glyph advanced, so the rendered line content changed
    assert frame0 != frame1;
    loader.stop();
    assert loader.intervalId == None;

    # setIndicator swaps the frame set / interval and restarts the animation
    loader.setIndicator(Indicator());
    assert loader.frames == ["A", "B", "C"];
    assert loader.intervalMs == 10;
    assert loader.currentFrame == 0;

    # ---------------------------------------------------------------
    # CancellableLoader: cancel keybinding aborts + fires onAbort
    # ---------------------------------------------------------------
    aborted_calls: list[bool] = [];
    cl = CancellableLoader(ui=fakeUi, spinnerColorFn=identity, messageColorFn=identity, message="Cancellable");
    cl.onAbort = lambda () -> None { aborted_calls.append(True); };
    assert cl.aborted() == False;
    cl.handleInput(ESC);   # tui.select.cancel default key
    assert cl.aborted() == True;
    assert len(aborted_calls) == 1;
    assert cl.signal().aborted == True;
    cl.dispose();   # calls inherited Loader.stop(); must not raise

    # ---------------------------------------------------------------
    # TruncatedText: long text truncates with ellipsis, honors width
    # ---------------------------------------------------------------
    tt = TruncatedText(text="the quick brown fox jumps over the lazy dog", paddingX=1, paddingY=0);
    ttLines = tt.render(float(20));
    assert len(ttLines) == 1;
    assert visibleWidth(ttLines[0]) == 20.0;
    assert "..." in ttLines[0];
    assert "lazy dog" not in ttLines[0];

    # CJK-aware: wide glyphs still respected by width budget
    ttCjk = TruncatedText(text="世界世界世界世界世界世界世界世界", paddingX=0, paddingY=0);
    cjkLines = ttCjk.render(float(10));
    assert len(cjkLines) == 1;
    assert visibleWidth(cjkLines[0]) == 10.0;

    # short text fits untouched (no ellipsis) and pads to width
    ttShort = TruncatedText(text="hi", paddingX=0, paddingY=0);
    shortLines = ttShort.render(float(10));
    assert shortLines[0].startswith("hi");
    assert visibleWidth(shortLines[0]) == 10.0;
    assert "..." not in shortLines[0];

    # ---------------------------------------------------------------
    # Spacer: blank lines matching requested height, any width
    # ---------------------------------------------------------------
    sp = Spacer(lines=3);
    spLines = sp.render(float(40));
    assert len(spLines) == 3;
    for line in spLines {
        assert line == "";
    }
    sp.setLines(1);
    assert len(sp.render(float(5))) == 1;

    # ---------------------------------------------------------------
    # terminal_colors: escape/response parsing on known inputs
    # ---------------------------------------------------------------
    assert hexToRgb("#336699") == {"r": 51, "g": 102, "b": 153};

    osc11 = f"{ESC}]11;rgb:3333/6666/9999{ESC}\\";
    assert isOsc11BackgroundColorResponse(osc11) == True;
    parsed = parseOsc11BackgroundColor(osc11);
    assert parsed == {"r": 51, "g": 102, "b": 153};

    osc11Hex = f"{ESC}]11;#336699\x07";
    parsedHex = parseOsc11BackgroundColor(osc11Hex);
    assert parsedHex == {"r": 51, "g": 102, "b": 153};

    assert isOsc11BackgroundColorResponse("not an osc11 response") == False;
    assert parseOsc11BackgroundColor("garbage") == None;

    darkReport = f"{ESC}[?997;1n";
    lightReport = f"{ESC}[?997;2n";
    assert parseTerminalColorSchemeReport(darkReport) == "dark";
    assert parseTerminalColorSchemeReport(lightReport) == "light";
    assert parseTerminalColorSchemeReport("garbage") == None;

    # ---------------------------------------------------------------
    # SelectList: highlight, move selection, wraparound, truncation
    # ---------------------------------------------------------------
    items = [
        {"value": "alpha", "label": "Alpha Command", "description": "does the alpha thing, with a very long description to force truncation of the description column"},
        {"value": "beta", "label": "Beta Command", "description": "does the beta thing"},
        {"value": "gamma", "label": "Gamma Command With A Really Quite Long Label Indeed", "description": "gamma desc"},
    ];
    theme = SelectTheme();
    sl = SelectList(items, 5, theme, {});
    assert sl.selectedIndex == 0;

    lines = sl.render(float(60));
    assert len(lines) == 3;
    assert lines[0].startswith("[");   # selectedText wraps index 0 in brackets
    assert not lines[1].startswith("[");

    # move down: selection advances, no longer highlighting row 0
    sl.handleInput(f"{ESC}[B");   # down arrow -> tui.select.down
    assert sl.selectedIndex == 1;
    lines2 = sl.render(float(60));
    assert lines2[1].startswith("[");
    assert not lines2[0].startswith("[");

    # move down twice more wraps back to index 0
    sl.handleInput(f"{ESC}[B");
    assert sl.selectedIndex == 2;
    sl.handleInput(f"{ESC}[B");
    assert sl.selectedIndex == 0;   # wrapped past the end

    # move up from index 0 wraps to the last item
    sl.handleInput(f"{ESC}[A");    # up arrow -> tui.select.up
    assert sl.selectedIndex == 2;

    # long label truncated with ellipsis in the rendered row
    assert "Really Quite Long Label Indeed" not in lines[2];

    # narrow width forces truncation via truncateToWidth in the primary column
    narrow = sl.render(float(25));
    assert len(narrow) == 3;
    for line in narrow {
        assert visibleWidth(line) <= 25.0 or "[" in line;  # bracket theme adds no width padding
    }

    # cancel / confirm callbacks
    cancelled: list[bool] = [];
    selected: list[any] = [];
    sl.onCancel = lambda () -> None { cancelled.append(True); };
    sl.onSelect = lambda (item: any) -> None { selected.append(item); };
    sl.handleInput(ESC);        # escape -> tui.select.cancel
    assert len(cancelled) == 1;
    sl.handleInput(chr(13));    # enter -> tui.select.confirm
    assert len(selected) == 1;
    assert selected[0]["value"] == "gamma";

    # empty filter result path
    sl.setFilter("zzz-no-match");
    emptyLines = sl.render(float(40));
    assert emptyLines == ["  No matching commands"];

    print("smoke_components OK");
}
