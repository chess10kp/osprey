"""Runtime smoke that instantiates the full Editor and drives it end-to-end.

Constructs Editor with minimal tui/theme stubs and walks the core editing
surface: text set/get, cursor query, insertion, cursor motion, undo, and a
full render() pass (which exercises layoutText, the cursor-line search, and
the borderColor path). Guards against the JS-ism regressions that jac check
cannot see: dict dot-access on state, Map .set/.delete on pastes, JS regex
.exec/.map, Number.isFinite, String.fromCharCode, Object.assign, findIndex,
and indexOf/lastIndexOf.

See also smoke_editor_input.jac (handleInput/keybindings) and
smoke_pipeline.jac (StdinBuffer -> handleInput).

Run: jac run smoke_editor.jac
"""

import from src.components.editor { Editor }

obj FakeTerminal {
    has rows: int = 24;
    has columns: int = 80;
}

obj FakeTui {
    has terminal: FakeTerminal = FakeTerminal();
    has renderCount: int = 0;
    def requestRender() -> None {
        self.renderCount += 1;
    }
}

def identityColor(text: str) -> str {
    return text;
}

obj FakeTheme {
    has borderColor: any = identityColor;
    has selectList: any = {};
}

with entry {
    tui = FakeTui();
    theme = FakeTheme();
    ed = Editor(tui, theme, {});

    # --- fresh editor starts empty at origin ---
    assert ed.getText() == "";
    assert ed.getLines() == [""];
    cur = ed.getCursor();
    assert cur["line"] == 0;
    assert cur["col"] == 0;

    # --- setText / getText / getLines round-trips across newlines ---
    ed.setText("hello world");
    assert ed.getText() == "hello world";
    ed.setText("line one\nline two\nline three");
    assert ed.getLines() == ["line one", "line two", "line three"];
    endCur = ed.getCursor();
    assert endCur["line"] == 2;
    assert endCur["col"] == len("line three");

    # --- insertTextAtCursor mutates state via the object path (not dict) ---
    ed.setText("ab");
    ed.insertTextAtCursor("XY");
    assert ed.getText() == "abXY";

    # --- undo restores the pre-insert snapshot (Object.assign port) ---
    ed.undo();
    assert ed.getText() == "ab";

    # --- moveCursor steps one grapheme per call in the sign direction ---
    ed.setText("abcdef");
    ed.moveCursor(0, -1);
    ed.moveCursor(0, -1);
    ed.moveCursor(0, -1);
    midCur = ed.getCursor();
    assert midCur["col"] == 3;

    # --- render() drives layoutText, cursor-line search, borderColor ---
    ed.setText("first\nsecond");
    lines = ed.render(40);
    assert isinstance(lines, list);
    assert len(lines) > 0;
    for row in lines {
        assert isinstance(row, str);
    }

    # --- handlePaste: a large paste collapses to a [paste #N ...] marker ---
    # (exercises .split port, the Map .set on pastes, and getExpandedText).
    ed.setText("");
    bigPaste = "\n".join(["row " + str(n) for n in range(0, 15)]);
    ed.handlePaste(bigPaste);
    shownText = ed.getText();
    assert "[paste #1" in shownText;
    # getExpandedText restores the original content via the sub() replacer port.
    assert ed.getExpandedText() == bigPaste;
    # validPasteIds tracks the live marker id.
    assert 1 in ed.validPasteIds();

    # --- deleting the marker grapheme drops the paste (Map .delete port) ---
    ed.handleBackspace();
    assert "[paste #1" not in ed.getText();
    assert len(ed.validPasteIds()) == 0;

    # --- setPaddingX / setAutocompleteMaxVisible (isfinite port) ---
    ed.setPaddingX(2);
    assert ed.getPaddingX() == 2;
    ed.setAutocompleteMaxVisible(8);
    assert ed.getAutocompleteMaxVisible() == 8;

    print("smoke_editor: OK");
}
