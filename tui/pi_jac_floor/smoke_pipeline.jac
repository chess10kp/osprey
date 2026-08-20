"""End-to-end pipeline smoke: raw bytes -> StdinBuffer -> Editor.handleInput.

Proves the input stack composes under jac run: terminal bytes are segmented
by StdinBuffer, each sequence is fed to Editor.handleInput (which resolves
keybindings internally), and the editor state reflects typed text, arrows,
and bracketed paste.

Run: jac run smoke_pipeline.jac
"""

import from src.components.editor { Editor }
import from src.stdin_buffer { StdinBuffer }

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

def feedEditor(ed: Editor, raw: str) -> None {
    sb = StdinBuffer();
    sb.on("data", lambda (seq: any) -> any { ed.handleInput(seq); });
    sb.on("paste", lambda (content: any) -> any { ed.handlePaste(content); });
    sb.process(raw);
}

with entry {
    ESC = chr(27);
    ed = Editor(FakeTui(), FakeTheme(), {});

    # --- type through the buffer segmenter ---
    feedEditor(ed, "hello");
    assert ed.getText() == "hello";

    # --- arrow-left then insert via pipeline ---
    feedEditor(ed, f"{ESC}[D{ESC}[D!");
    assert ed.getText() == "hel!lo";

    # --- bracketed paste: StdinBuffer lifts to paste event -> handlePaste ---
    ed.setText("");
    feedEditor(ed, f"{ESC}[200~multi\nline{ESC}[201~");
    assert ed.getText() == "multi\nline";

    # --- render still works after pipeline-driven edits ---
    lines = ed.render(40);
    assert len(lines) > 0;

    print("smoke_pipeline: OK");
}
