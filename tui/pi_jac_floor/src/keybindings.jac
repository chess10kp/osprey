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
        for _jx_item0 in Object.entries(self.userBindings) {
            keybinding = _jx_item0[0];
            keys = _jx_item0[1];
            if not (keybinding in self.definitions) {
                continue;
            }
            for key in normalizeKeys(keys) {
                claimants = ((lambda (_jx_null0: any) -> any { return (_jx_null0 if _jx_null0 is not None else set()); })(userClaims.get(key)));
                claimants.add(keybinding);
                userClaims.set(key, claimants);
            }
        }
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
    def matches(data: str, keybinding: any) -> bool {
        keys = ((lambda (_jx_null1: any) -> any { return (_jx_null1 if _jx_null1 is not None else []); })(self.keysById.get(keybinding)));
        for key in keys {
            if matchesKey(data, key) {
                return True;
            }
        }
        return False;
    }
    def getKeys(keybinding: any) -> list[any] {
        return [*((lambda (_jx_null2: any) -> any { return (_jx_null2 if _jx_null2 is not None else []); })(self.keysById.get(keybinding)))];
    }
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
        for id_j in Object.keys(self.definitions) {
            keys = ((lambda (_jx_null3: any) -> any { return (_jx_null3 if _jx_null3 is not None else []); })(self.keysById.get(id_j)));
            resolved[id_j] = ((keys[0] as any) if (len(keys) == 1) else [*keys]);
        }
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
