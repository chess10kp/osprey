"""Runtime smoke for Editor.handleInput — keybinding-driven editing surface.

Extends smoke_editor.jac (direct method calls) by driving the full
handleInput() path: printable keys, arrows, kill/yank/undo keybindings,
newline insertion, and bracketed-paste framing. This is the last major
Editor surface not previously exercised at runtime.

Run: jac run smoke_editor_input.jac
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
    ESC = chr(27);
    tui = FakeTui();
    theme = FakeTheme();
    ed = Editor(tui, theme, {});

    # --- printable keys via handleInput ---
    for ch in "hello" {
        ed.handleInput(ch);
    }
    assert ed.getText() == "hello";
    cur = ed.getCursor();
    assert cur["line"] == 0;
    assert cur["col"] == 5;

    # --- backspace keybinding ---
    ed.handleInput(chr(8));
    assert ed.getText() == "hell";
    assert ed.getCursor()["col"] == 4;

    # --- arrow left/right ---
    ed.handleInput(f"{ESC}[D");
    ed.handleInput(f"{ESC}[D");
    assert ed.getCursor()["col"] == 2;
    ed.handleInput(f"{ESC}[C");
    ed.handleInput("X");
    assert ed.getText() == "helXl";

    # --- word motion via ctrl+left / ctrl+right ---
    ed.setText("hello world foo");
    ed.handleInput(f"{ESC}[1;5D");
    assert ed.getCursor()["col"] == 12;
    ed.handleInput(f"{ESC}[1;5C");
    assert ed.getCursor()["col"] == 15;

    # --- kill-to-line-start (ctrl+u) then yank (ctrl+y) ---
    ed.setText("hello world");
    ed.handleInput(chr(21));
    assert ed.getText() == "";
    assert ed.getCursor()["col"] == 0;
    ed.handleInput(chr(25));
    assert ed.getText() == "hello world";
    assert ed.getCursor()["col"] == 11;

    # --- kill-to-line-end (ctrl+k) then yank ---
    ed.setText("abcdef");
    for _ in range(0, 4) {
        ed.handleInput(f"{ESC}[D");
    }
    ed.handleInput(chr(11));
    assert ed.getText() == "ab";
    ed.handleInput(chr(25));
    assert ed.getText() == "abcdef";

    # --- delete-word-backward (ctrl+w) + undo keybinding ---
    ed.setText("hello world");
    ed.handleInput(chr(23));
    assert ed.getText() == "hello ";
    ed.handleInput(chr(31));   # ctrl+- -> undo
    assert ed.getText() == "hello world";

    # --- newline inserts a line break ---
    ed.setText("line one");
    ed.handleInput("\n");
    assert ed.getLines() == ["line one", ""];
    assert ed.getCursor()["line"] == 1;

    # --- bracketed paste via handleInput framing ---
    ed.setText("");
    pasteBody = "pasted\ncontent";
    ed.handleInput(f"{ESC}[200~{pasteBody}{ESC}[201~");
    assert ed.getText() == pasteBody;

    print("smoke_editor_input: OK");
}
