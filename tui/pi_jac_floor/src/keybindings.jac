import from "./keys.jac" { matchesKey }

glob:pub TUI_KEYBINDINGS = {"tui.editor.cursorUp": {"defaultKeys": "up", "description": "Move cursor up"}, "tui.editor.cursorDown": {"defaultKeys": "down", "description": "Move cursor down"}, "tui.editor.cursorLeft": {"defaultKeys": ["left", "ctrl+b"], "description": "Move cursor left"}, "tui.editor.cursorRight": {"defaultKeys": ["right", "ctrl+f"], "description": "Move cursor right"}, "tui.editor.cursorWordLeft": {"defaultKeys": ["alt+left", "ctrl+left", "alt+b"], "description": "Move cursor word left"}, "tui.editor.cursorWordRight": {"defaultKeys": ["alt+right", "ctrl+right", "alt+f"], "description": "Move cursor word right"}, "tui.editor.cursorLineStart": {"defaultKeys": ["home", "ctrl+a"], "description": "Move to line start"}, "tui.editor.cursorLineEnd": {"defaultKeys": ["end", "ctrl+e"], "description": "Move to line end"}, "tui.editor.jumpForward": {"defaultKeys": "ctrl+]", "description": "Jump forward to character"}, "tui.editor.jumpBackward": {"defaultKeys": "ctrl+alt+]", "description": "Jump backward to character"}, "tui.editor.pageUp": {"defaultKeys": "pageUp", "description": "Page up"}, "tui.editor.pageDown": {"defaultKeys": "pageDown", "description": "Page down"}, "tui.editor.deleteCharBackward": {"defaultKeys": "backspace", "description": "Delete character backward"}, "tui.editor.deleteCharForward": {"defaultKeys": ["delete", "ctrl+d"], "description": "Delete character forward"}, "tui.editor.deleteWordBackward": {"defaultKeys": ["ctrl+w", "alt+backspace"], "description": "Delete word backward"}, "tui.editor.deleteWordForward": {"defaultKeys": ["alt+d", "alt+delete"], "description": "Delete word forward"}, "tui.editor.deleteToLineStart": {"defaultKeys": "ctrl+u", "description": "Delete to line start"}, "tui.editor.deleteToLineEnd": {"defaultKeys": "ctrl+k", "description": "Delete to line end"}, "tui.editor.yank": {"defaultKeys": "ctrl+y", "description": "Yank"}, "tui.editor.yankPop": {"defaultKeys": "alt+y", "description": "Yank pop"}, "tui.editor.undo": {"defaultKeys": "ctrl+-", "description": "Undo"}, "tui.input.newLine": {"defaultKeys": ["shift+enter", "ctrl+j"], "description": "Insert newline"}, "tui.input.submit": {"defaultKeys": "enter", "description": "Submit input"}, "tui.input.tab": {"defaultKeys": "tab", "description": "Tab / autocomplete"}, "tui.input.copy": {"defaultKeys": "ctrl+c", "description": "Copy selection"}, "tui.select.up": {"defaultKeys": "up", "description": "Move selection up"}, "tui.select.down": {"defaultKeys": "down", "description": "Move selection down"}, "tui.select.pageUp": {"defaultKeys": "pageUp", "description": "Selection page up"}, "tui.select.pageDown": {"defaultKeys": "pageDown", "description": "Selection page down"}, "tui.select.confirm": {"defaultKeys": "enter", "description": "Confirm selection"}, "tui.select.cancel": {"defaultKeys": ["escape", "ctrl+c"], "description": "Cancel selection"}};

def normalizeKeys(keys: any | list[any] | None) -> list[any] {
    if (keys == None) {
        return [];
    }
    keyList = (keys if Array.isArray(keys) else [keys]);
    seen = set();
    result: list[any] = [];
    for key in keyList {
        if not seen.has(key) {
            seen.add(key);
            result.append(key);
        }
    }
    return result;
}

obj:pub KeybindingsManager {
    has definitions: any;
    has userBindings: any;
    has keysById: any = {};
    has conflicts: list[any] = [];
    def __init__(definitions: any, userBindings: any = {}) -> None {
        self.definitions = definitions;
        self.userBindings = userBindings;
        self.rebuild();
    }
    def rebuild() -> None {
        self.keysById.clear();
        self.conflicts = [];
        userClaims = {};
        # JS2JAC-HOLE[E7214]:
        # | for (const [keybinding, keys] of Object.entries(this.userBindings)) {
        # | 			if (!(keybinding in this.definitions)) continue;
        # | 			for (const key of normalizeKeys(keys)) {
        # | 				const claimants = userClaims.get(key) ?? new Set<Keybinding>();
        # | 				claimants.add(keybinding as Keybinding);
        # | 				userClaims.set(key, claimants);
        # | 			}
        # | 		}
        for _jx_item0 in userClaims {
            key = _jx_item0[0];
            keybindings = _jx_item0[1];
            if (keybindings.size > 1) {
                self.conflicts.append({"key": key, "keybindings": [*keybindings]});
            }
        }
        for _jx_item0 in Object.entries(self.definitions) {
            id = _jx_item0[0];
            definition = _jx_item0[1];
            userKeys = self.userBindings[id_j];
            keys = (normalizeKeys(definition.defaultKeys) if (userKeys == None) else normalizeKeys(userKeys));
            self.keysById.set(id_j, keys);
        }
    }
    # JS2JAC-HOLE[E7205] Class method produced no output:
    # | matches(data: string, keybinding: Keybinding): boolean {
    # | 		const keys = this.keysById.get(keybinding) ?? [];
    # | 		for (const key of keys) {
    # | 			if (matchesKey(data, key)) return true;
    # | 		}
    # | 		return false;
    # | 	}
    # JS2JAC-HOLE[E7205] Class method produced no output:
    # | getKeys(keybinding: Keybinding): KeyId[] {
    # | 		return [...(this.keysById.get(keybinding) ?? [])];
    # | 	}
    def getDefinition(keybinding: any) -> any {
        return self.definitions[keybinding];
    }
    def getConflicts() -> list[any] {
        return [{**conflict, "keybindings": [*conflict.keybindings]} for conflict in self.conflicts];
    }
    def setUserBindings(userBindings: any) -> None {
        self.userBindings = userBindings;
        self.rebuild();
    }
    def getUserBindings() -> any {
        return {**self.userBindings};
    }
    def getResolvedBindings() -> any {
        resolved: any = {};
        # JS2JAC-HOLE[E7214]:
        # | for (const id of Object.keys(this.definitions)) {
        # | 			const keys = this.keysById.get(id as Keybinding) ?? [];
        # | 			resolved[id] = keys.length === 1 ? keys[0]! : [...keys];
        # | 		}
        return resolved;
    }
}

glob globalKeybindings: KeybindingsManager | None = None;

def:pub setKeybindings(keybindings: KeybindingsManager) -> None {
    globalKeybindings = keybindings;
}

def:pub getKeybindings() -> KeybindingsManager {
    if not globalKeybindings {
        globalKeybindings = KeybindingsManager(TUI_KEYBINDINGS);
    }
    return globalKeybindings;
}
