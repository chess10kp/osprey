"""Runtime smoke for the Input component (src/components/input.jac).

Exercises typing, cursor motion, backspace/forward-delete, word motion
(ctrl+left/right), kill-ring operations (ctrl+u/ctrl+k/ctrl+w -> KillRing,
ctrl+y yank), undo (UndoStack), and render()'s cursor-marker placement.

The js2jac output left several check-passing-but-crashing JS leftovers here:
`.some()` on a list, dict dot-access on UndoStack snapshots, KillRing
`.append`/`len()` calls against an API that is actually `.push()`/`.length()`,
a doubled-escape literal in the reverse-video cursor escape sequence, and a
`cursor: float` field used to slice strings (Python raises on float index).
This smoke proves the Jac-native fixes run correctly.

Note: yankPop (alt+y) and undo (ctrl+-) are exercised via direct method
calls rather than raw byte sequences -- their raw-escape matching in
keys.jac has independent doubled-escape bugs out of scope for this module.

Run: jac run smoke_input_component.jac
"""

import from src.components.input { Input }
import from src.tui { CURSOR_MARKER }

with entry {
    ESC = chr(27);

    # --- typing, cursor advances one char per insertCharacter call ---
    inp = Input();
    for ch in "hello" {
        inp.handleInput(ch);
    }
    assert inp.getValue() == "hello";
    assert inp.cursor == 5;

    # --- backspace (raw \b, matchesRawBackspace) ---
    inp.handleInput(chr(8));
    assert inp.getValue() == "hell";
    assert inp.cursor == 4;

    # --- cursor left/right (arrow escape sequences) ---
    inp.handleInput(f"{ESC}[D");
    inp.handleInput(f"{ESC}[D");
    assert inp.cursor == 2;
    inp.handleInput(f"{ESC}[C");
    assert inp.cursor == 3;
    inp.handleInput("X");
    assert inp.getValue() == "helXl";
    assert inp.cursor == 4;

    # --- word motion: findWordBackward/findWordForward wired through ---
    inp2 = Input();
    inp2.setValue("hello world foo");
    inp2.cursor = 15;
    inp2.moveWordBackwards();
    assert inp2.cursor == 12;
    inp2.moveWordBackwards();
    assert inp2.cursor == 6;
    inp2.moveWordBackwards();
    assert inp2.cursor == 0;
    inp2.moveWordForwards();
    assert inp2.cursor == 5;
    inp2.moveWordForwards();
    assert inp2.cursor == 11;
    inp2.moveWordForwards();
    assert inp2.cursor == 15;

    # --- ctrl+left / ctrl+right also drive word motion via handleInput ---
    inp2b = Input();
    inp2b.setValue("hello world foo");
    inp2b.cursor = 15;
    inp2b.handleInput(f"{ESC}[1;5D");   # ctrl+left
    assert inp2b.cursor == 12;
    inp2b.handleInput(f"{ESC}[1;5C");   # ctrl+right
    assert inp2b.cursor == 15;

    # --- kill-to-line-start (ctrl+u) then yank (ctrl+y) round-trips ---
    inp3 = Input();
    inp3.setValue("hello world");
    inp3.cursor = 11;
    inp3.handleInput(chr(21));   # ctrl+u -> deleteToLineStart
    assert inp3.getValue() == "";
    assert inp3.cursor == 0;
    inp3.handleInput(chr(25));   # ctrl+y -> yank
    assert inp3.getValue() == "hello world";
    assert inp3.cursor == 11;

    # --- kill-to-line-end (ctrl+k) then yank round-trips ---
    inp4 = Input();
    inp4.setValue("abcdef");
    inp4.cursor = 2;
    inp4.handleInput(chr(11));   # ctrl+k -> deleteToLineEnd
    assert inp4.getValue() == "ab";
    assert inp4.cursor == 2;
    inp4.handleInput(chr(25));   # ctrl+y -> yank
    assert inp4.getValue() == "abcdef";
    assert inp4.cursor == 6;

    # --- delete-word-backward (ctrl+w) + undo restores prior snapshot ---
    inp5 = Input();
    inp5.setValue("hello world");
    inp5.cursor = 11;
    inp5.handleInput(chr(23));   # ctrl+w -> deleteWordBackwards
    assert inp5.getValue() == "hello ";
    assert inp5.cursor == 6;
    inp5.undo();
    assert inp5.getValue() == "hello world";
    assert inp5.cursor == 11;

    # --- yank-pop: rotate the kill ring and swap the yanked text ---
    inp6 = Input();
    inp6.killRing.push("AAA", {"prepend": False, "accumulate": False});
    inp6.killRing.push("BBB", {"prepend": False, "accumulate": False});
    inp6.yank();
    assert inp6.getValue() == "BBB";
    assert inp6.cursor == 3;
    inp6.yankPop();
    assert inp6.getValue() == "AAA";
    assert inp6.cursor == 3;

    # --- render(): prompt, plain text, and reverse-video cursor marker ---
    inp7 = Input();
    inp7.setValue("ab");
    inp7.cursor = 1;
    inp7.focused = True;
    lines = inp7.render(10.0);
    assert len(lines) == 1;
    line = lines[0];
    assert line.startswith("> a");
    assert CURSOR_MARKER in line;
    assert f"{ESC}[7mb{ESC}[27m" in line;

    print("smoke_input_component: OK");
}
