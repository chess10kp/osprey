"""Runtime smoke for the emacs-style editor state modules.

Exercises keybindings.jac (key-sequence -> keybinding-id resolution, user
override / conflict tracking), kill_ring.jac (kill/yank/yank-pop ring),
undo_stack.jac (push/pop undo history), and native_modifiers.jac (native
modifier-key probe degradation path). These are check-passing-but-crashing
JS leftovers (Object.entries/keys, .has/.set/.size on dict/set, dot-access
on dict literals) rewritten Jac-native.

Run: jac run smoke_editor_state.jac
"""

import from src.keybindings { KeybindingsManager, TUI_KEYBINDINGS, normalizeKeys }
import from src.kill_ring { KillRing }
import from src.undo_stack { UndoStack }
import from src.native_modifiers { isNativeModifierPressed, loadNativeModifiersHelper }

glob ESC = chr(27);

with entry {
    # --- keybindings: normalizeKeys dedupes and wraps a bare string ---
    assert normalizeKeys(None) == [];
    assert normalizeKeys("up") == ["up"];
    assert normalizeKeys(["ctrl+a", "ctrl+a", "home"]) == ["ctrl+a", "home"];

    # --- keybindings: default manager resolves default keys ---
    mgr = KeybindingsManager(TUI_KEYBINDINGS, {});
    assert mgr.matches(f"{ESC}[A", "tui.editor.cursorUp") == True;
    assert mgr.matches(chr(2), "tui.editor.cursorLeft") == True;   # ctrl+b
    assert mgr.matches("z", "tui.editor.cursorUp") == False;
    assert mgr.getKeys("tui.editor.cursorLeft") == ["left", "ctrl+b"];
    assert mgr.getConflicts() == [];

    # --- keybindings: user override + conflict detection ---
    userBindings = {
        "tui.editor.cursorUp": "ctrl+p",
        "tui.editor.cursorDown": "ctrl+p",
    };
    mgr2 = KeybindingsManager(TUI_KEYBINDINGS, userBindings);
    assert mgr2.matches(chr(16), "tui.editor.cursorUp") == True;    # ctrl+p
    assert mgr2.matches(f"{ESC}[A", "tui.editor.cursorUp") == False; # default no longer bound
    conflicts = mgr2.getConflicts();
    assert len(conflicts) == 1;
    assert conflicts[0]["key"] == "ctrl+p";
    assert set(conflicts[0]["keybindings"]) == {"tui.editor.cursorUp", "tui.editor.cursorDown"};
    resolved = mgr2.getResolvedBindings();
    assert resolved["tui.editor.cursorUp"] == "ctrl+p";
    assert resolved["tui.editor.cursorLeft"] == ["left", "ctrl+b"];

    # setUserBindings rebuilds and getUserBindings returns a live snapshot copy
    mgr2.setUserBindings({});
    assert mgr2.getConflicts() == [];
    assert mgr2.matches(f"{ESC}[A", "tui.editor.cursorUp") == True;
    snap = mgr2.getUserBindings();
    snap["tui.editor.cursorUp"] = "x";
    assert mgr2.getUserBindings() == {};   # mutating the snapshot doesn't leak back

    # --- kill_ring: push, peek, rotate, accumulate ---
    kr = KillRing();
    assert kr.length() == 0;
    kr.push("foo", {"accumulate": False, "prepend": False});
    kr.push("bar", {"accumulate": False, "prepend": False});
    assert kr.length() == 2;
    assert kr.peek() == "bar";               # latest kill is on top

    # accumulate=True merges into the last entry instead of pushing a new one
    kr.push("baz", {"accumulate": True, "prepend": False});
    assert kr.length() == 2;
    assert kr.peek() == "barbaz";
    kr.push("Q", {"accumulate": True, "prepend": True});
    assert kr.peek() == "Qbarbaz";

    # rotate moves the top of the ring to the bottom (yank-pop cycling)
    kr2 = KillRing();
    kr2.push("one", {"accumulate": False, "prepend": False});
    kr2.push("two", {"accumulate": False, "prepend": False});
    kr2.push("three", {"accumulate": False, "prepend": False});
    assert kr2.peek() == "three";
    kr2.rotate();
    assert kr2.peek() == "two";
    kr2.rotate();
    assert kr2.peek() == "one";
    kr2.rotate();
    assert kr2.peek() == "three";   # full cycle back to start

    # empty-text push is a no-op
    kr3 = KillRing();
    kr3.push("", {"accumulate": False, "prepend": False});
    assert kr3.length() == 0;
    assert kr3.peek() == None;

    # --- undo_stack: push / pop / clear / length, deep-copy isolation ---
    us = UndoStack();
    assert us.length() == 0;
    state1 = {"text": "a", "cursor": 1};
    state2 = {"text": "ab", "cursor": 2};
    us.push(state1);
    us.push(state2);
    assert us.length() == 2;

    # mutating the original after push must not affect the stored snapshot
    state2["text"] = "MUTATED";
    top = us.pop();
    assert top["text"] == "ab";   # deepcopy isolated it from the later mutation
    assert us.length() == 1;

    prior = us.pop();
    assert prior["text"] == "a";
    assert us.length() == 0;

    # redo-branch truncation pattern: push after undo drops the redone-away state
    us.push({"text": "a"});
    us.push({"text": "ab"});
    us.push({"text": "abc"});
    undone = us.pop();          # "undo" -- pop the most recent
    assert undone["text"] == "abc";
    assert us.length() == 2;
    us.push({"text": "abX"});   # new edit after undo -- redo branch is gone
    assert us.length() == 3;
    assert us.pop()["text"] == "abX";
    assert us.pop()["text"] == "ab";
    assert us.pop()["text"] == "a";
    us.clear();
    assert us.length() == 0;

    # --- native_modifiers: no dlopen-able .node addon under Jac -> always degrades ---
    assert loadNativeModifiersHelper() == None;
    assert isNativeModifierPressed({"shift": True}) == False;
    assert isNativeModifierPressed("shift") == False;

    print("smoke_editor_state OK (keybindings / kill_ring / undo_stack / native_modifiers)");
}
