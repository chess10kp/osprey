import from re { compile, search }
import from os { environ }

glob _kittyProtocolActive = False;

def:pub setKittyProtocolActive(active: bool) -> None {
    _kittyProtocolActive = active;
}

def:pub isKittyProtocolActive() -> bool {
    return _kittyProtocolActive;
}

glob:pub Key = {"escape": "escape", "esc": "esc", "enter": "enter", "return": "return", "tab": "tab", "space": "space", "backspace": "backspace", "delete": "delete", "insert": "insert", "clear": "clear", "home": "home", "end": "end", "pageUp": "pageUp", "pageDown": "pageDown", "up": "up", "down": "down", "left": "left", "right": "right", "f1": "f1", "f2": "f2", "f3": "f3", "f4": "f4", "f5": "f5", "f6": "f6", "f7": "f7", "f8": "f8", "f9": "f9", "f10": "f10", "f11": "f11", "f12": "f12", "backtick": "`", "hyphen": "-", "equals": "=", "leftbracket": "[", "rightbracket": "]", "backslash": "\\", "semicolon": ";", "quote": "'", "comma": ",", "period": ".", "slash": "/", "exclamation": "!", "at": "@", "hash": "#", "dollar": "$", "percent": "%", "caret": "^", "ampersand": "&", "asterisk": "*", "leftparen": "(", "rightparen": ")", "underscore": "_", "plus": "+", "pipe": "|", "tilde": "~", "leftbrace": "{", "rightbrace": "}", "colon": ":", "lessthan": "<", "greaterthan": ">", "question": "?", "ctrl": lambda (key: any) -> any { return f"ctrl+{key}"; }, "shift": lambda (key: any) -> any { return f"shift+{key}"; }, "alt": lambda (key: any) -> any { return f"alt+{key}"; }, "super": lambda (key: any) -> any { return f"super+{key}"; }, "ctrlShift": lambda (key: any) -> any { return f"ctrl+shift+{key}"; }, "shiftCtrl": lambda (key: any) -> any { return f"shift+ctrl+{key}"; }, "ctrlAlt": lambda (key: any) -> any { return f"ctrl+alt+{key}"; }, "altCtrl": lambda (key: any) -> any { return f"alt+ctrl+{key}"; }, "shiftAlt": lambda (key: any) -> any { return f"shift+alt+{key}"; }, "altShift": lambda (key: any) -> any { return f"alt+shift+{key}"; }, "ctrlSuper": lambda (key: any) -> any { return f"ctrl+super+{key}"; }, "superCtrl": lambda (key: any) -> any { return f"super+ctrl+{key}"; }, "shiftSuper": lambda (key: any) -> any { return f"shift+super+{key}"; }, "superShift": lambda (key: any) -> any { return f"super+shift+{key}"; }, "altSuper": lambda (key: any) -> any { return f"alt+super+{key}"; }, "superAlt": lambda (key: any) -> any { return f"super+alt+{key}"; }, "ctrlShiftAlt": lambda (key: any) -> any { return f"ctrl+shift+alt+{key}"; }, "ctrlShiftSuper": lambda (key: any) -> any { return f"ctrl+shift+super+{key}"; }};

glob SYMBOL_KEYS = set(["`", "-", "=", "[", "]", "\\", ";", "'", ",", ".", "/", "!", "@", "#", "$", "%", "^", "&", "*", "(", ")", "_", "+", "|", "~", "{", "}", ":", "<", ">", "?"]);

glob MODIFIERS = {"shift": 1, "alt": 2, "ctrl": 4, "super": 8};

glob LOCK_MASK = (64 + 128);

glob CODEPOINTS = {"escape": 27, "tab": 9, "enter": 13, "space": 32, "backspace": 127, "kpEnter": 57414};

glob ARROW_CODEPOINTS = {"up": -1, "down": -2, "right": -3, "left": -4};

glob FUNCTIONAL_CODEPOINTS = {"delete": -10, "insert": -11, "pageUp": -12, "pageDown": -13, "home": -14, "end": -15};

glob KITTY_FUNCTIONAL_KEY_EQUIVALENTS = dict([[57399, 48], [57400, 49], [57401, 50], [57402, 51], [57403, 52], [57404, 53], [57405, 54], [57406, 55], [57407, 56], [57408, 57], [57409, 46], [57410, 47], [57411, 42], [57412, 45], [57413, 43], [57415, 61], [57416, 44], [57417, ARROW_CODEPOINTS.left], [57418, ARROW_CODEPOINTS.right], [57419, ARROW_CODEPOINTS.up], [57420, ARROW_CODEPOINTS.down], [57421, FUNCTIONAL_CODEPOINTS.pageUp], [57422, FUNCTIONAL_CODEPOINTS.pageDown], [57423, FUNCTIONAL_CODEPOINTS.home], [57424, FUNCTIONAL_CODEPOINTS.end], [57425, FUNCTIONAL_CODEPOINTS.insert], [57426, FUNCTIONAL_CODEPOINTS.delete]]);

def normalizeKittyFunctionalCodepoint(codepoint: float) -> float {
    return ((lambda (_jx_null0: any) -> any { return (_jx_null0 if _jx_null0 is not None else codepoint); })(KITTY_FUNCTIONAL_KEY_EQUIVALENTS.get(codepoint)));
}

def normalizeShiftedLetterIdentityCodepoint(codepoint: float, modifier: float) -> float {
    effectiveModifier = float(int(modifier) & int(float(~int(LOCK_MASK))));
    if (((float(int(effectiveModifier) & int(MODIFIERS.shift)) != 0) and (codepoint >= 65)) and (codepoint <= 90)) {
        return (codepoint + 32);
    }
    return codepoint;
}

glob LEGACY_KEY_SEQUENCES = {"up": ["\u001b[A", "\u001bOA"], "down": ["\u001b[B", "\u001bOB"], "right": ["\u001b[C", "\u001bOC"], "left": ["\u001b[D", "\u001bOD"], "home": ["\u001b[H", "\u001bOH", "\u001b[1~", "\u001b[7~"], "end": ["\u001b[F", "\u001bOF", "\u001b[4~", "\u001b[8~"], "insert": ["\u001b[2~"], "delete": ["\u001b[3~"], "pageUp": ["\u001b[5~", "\u001b[[5~"], "pageDown": ["\u001b[6~", "\u001b[[6~"], "clear": ["\u001b[E", "\u001bOE"], "f1": ["\u001bOP", "\u001b[11~", "\u001b[[A"], "f2": ["\u001bOQ", "\u001b[12~", "\u001b[[B"], "f3": ["\u001bOR", "\u001b[13~", "\u001b[[C"], "f4": ["\u001bOS", "\u001b[14~", "\u001b[[D"], "f5": ["\u001b[15~", "\u001b[[E"], "f6": ["\u001b[17~"], "f7": ["\u001b[18~"], "f8": ["\u001b[19~"], "f9": ["\u001b[20~"], "f10": ["\u001b[21~"], "f11": ["\u001b[23~"], "f12": ["\u001b[24~"]};

glob LEGACY_SHIFT_SEQUENCES = {"up": ["\u001b[a"], "down": ["\u001b[b"], "right": ["\u001b[c"], "left": ["\u001b[d"], "clear": ["\u001b[e"], "insert": ["\u001b[2$"], "delete": ["\u001b[3$"], "pageUp": ["\u001b[5$"], "pageDown": ["\u001b[6$"], "home": ["\u001b[7$"], "end": ["\u001b[8$"]};

glob LEGACY_CTRL_SEQUENCES = {"up": ["\u001bOa"], "down": ["\u001bOb"], "right": ["\u001bOc"], "left": ["\u001bOd"], "clear": ["\u001bOe"], "insert": ["\u001b[2^"], "delete": ["\u001b[3^"], "pageUp": ["\u001b[5^"], "pageDown": ["\u001b[6^"], "home": ["\u001b[7^"], "end": ["\u001b[8^"]};

glob LEGACY_SEQUENCE_KEY_IDS: any = {"\u001bOA": "up", "\u001bOB": "down", "\u001bOC": "right", "\u001bOD": "left", "\u001bOH": "home", "\u001bOF": "end", "\u001b[E": "clear", "\u001bOE": "clear", "\u001bOe": "ctrl+clear", "\u001b[e": "shift+clear", "\u001b[2~": "insert", "\u001b[2$": "shift+insert", "\u001b[2^": "ctrl+insert", "\u001b[3$": "shift+delete", "\u001b[3^": "ctrl+delete", "\u001b[[5~": "pageUp", "\u001b[[6~": "pageDown", "\u001b[a": "shift+up", "\u001b[b": "shift+down", "\u001b[c": "shift+right", "\u001b[d": "shift+left", "\u001bOa": "ctrl+up", "\u001bOb": "ctrl+down", "\u001bOc": "ctrl+right", "\u001bOd": "ctrl+left", "\u001b[5$": "shift+pageUp", "\u001b[6$": "shift+pageDown", "\u001b[7$": "shift+home", "\u001b[8$": "shift+end", "\u001b[5^": "ctrl+pageUp", "\u001b[6^": "ctrl+pageDown", "\u001b[7^": "ctrl+home", "\u001b[8^": "ctrl+end", "\u001bOP": "f1", "\u001bOQ": "f2", "\u001bOR": "f3", "\u001bOS": "f4", "\u001b[11~": "f1", "\u001b[12~": "f2", "\u001b[13~": "f3", "\u001b[14~": "f4", "\u001b[[A": "f1", "\u001b[[B": "f2", "\u001b[[C": "f3", "\u001b[[D": "f4", "\u001b[[E": "f5", "\u001b[15~": "f5", "\u001b[17~": "f6", "\u001b[18~": "f7", "\u001b[19~": "f8", "\u001b[20~": "f9", "\u001b[21~": "f10", "\u001b[23~": "f11", "\u001b[24~": "f12", "\u001bb": "alt+left", "\u001bf": "alt+right", "\u001bp": "alt+up", "\u001bn": "alt+down"};

def matchesLegacySequence(data: str, sequences: any) -> bool {
    return (data in sequences);
}

def matchesLegacyModifierSequence(data: str, key: any, modifier: float) -> bool {
    if (modifier == MODIFIERS.shift) {
        return matchesLegacySequence(data, LEGACY_SHIFT_SEQUENCES[key]);
    }
    if (modifier == MODIFIERS.ctrl) {
        return matchesLegacySequence(data, LEGACY_CTRL_SEQUENCES[key]);
    }
    return False;
}

glob _lastEventType: any = "press";

def:pub isKeyRelease(data: str) -> bool {
    if ("\u001b[200~" in data) {
        return False;
    }
    if ((((((((":3u" in data) or (":3~" in data)) or (":3A" in data)) or (":3B" in data)) or (":3C" in data)) or (":3D" in data)) or (":3H" in data)) or (":3F" in data)) {
        return True;
    }
    return False;
}

def:pub isKeyRepeat(data: str) -> bool {
    if ("\u001b[200~" in data) {
        return False;
    }
    if ((((((((":2u" in data) or (":2~" in data)) or (":2A" in data)) or (":2B" in data)) or (":2C" in data)) or (":2D" in data)) or (":2H" in data)) or (":2F" in data)) {
        return True;
    }
    return False;
}

def parseEventType(eventTypeStr: str | None) -> any {
    if not eventTypeStr {
        return "press";
    }
    eventType = int(eventTypeStr, 10);
    if (eventType == 2) {
        return "repeat";
    }
    if (eventType == 3) {
        return "release";
    }
    return "press";
}

def parseKittySequence(data: str) -> any | None {
    csiUMatch = search(r"^\x1b\[(\d+)(?::(\d*))?(?::(\d+))?(?:;(\d+))?(?::(\d+))?u$", data);
    if csiUMatch {
        codepoint = int((csiUMatch.group(1) as any), 10);
        shiftedKey = (int(csiUMatch.group(2), 10) if (csiUMatch.group(2) and (len(csiUMatch.group(2)) > 0)) else None);
        baseLayoutKey = (int(csiUMatch.group(3), 10) if csiUMatch.group(3) else None);
        modValue = (int(csiUMatch.group(4), 10) if csiUMatch.group(4) else 1);
        eventType = parseEventType(csiUMatch.group(5));
        _lastEventType = eventType;
        return {"codepoint": codepoint, "shiftedKey": shiftedKey, "baseLayoutKey": baseLayoutKey, "modifier": (modValue - 1), "eventType": eventType};
    }
    arrowMatch = search(r"^\x1b\[1;(\d+)(?::(\d+))?([ABCD])$", data);
    if arrowMatch {
        modValue = int((arrowMatch.group(1) as any), 10);
        eventType = parseEventType(arrowMatch.group(2));
        arrowCodes: any = {"A": -1, "B": -2, "C": -3, "D": -4};
        _lastEventType = eventType;
        return {"codepoint": (arrowCodes[(arrowMatch.group(3) as any)] as any), "modifier": (modValue - 1), "eventType": eventType};
    }
    funcMatch = search(r"^\x1b\[(\d+)(?:;(\d+))?(?::(\d+))?~$", data);
    if funcMatch {
        keyNum = int((funcMatch.group(1) as any), 10);
        modValue = (int(funcMatch.group(2), 10) if funcMatch.group(2) else 1);
        eventType = parseEventType(funcMatch.group(3));
        funcCodes: any = {2: FUNCTIONAL_CODEPOINTS.insert, 3: FUNCTIONAL_CODEPOINTS.delete, 5: FUNCTIONAL_CODEPOINTS.pageUp, 6: FUNCTIONAL_CODEPOINTS.pageDown, 7: FUNCTIONAL_CODEPOINTS.home, 8: FUNCTIONAL_CODEPOINTS.end};
        codepoint = funcCodes[keyNum];
        if (codepoint != None) {
            _lastEventType = eventType;
            return {"codepoint": codepoint, "modifier": (modValue - 1), "eventType": eventType};
        }
    }
    homeEndMatch = search(r"^\x1b\[1;(\d+)(?::(\d+))?([HF])$", data);
    if homeEndMatch {
        modValue = int((homeEndMatch.group(1) as any), 10);
        eventType = parseEventType(homeEndMatch.group(2));
        codepoint = (FUNCTIONAL_CODEPOINTS.home if (homeEndMatch.group(3) == "H") else FUNCTIONAL_CODEPOINTS.end);
        _lastEventType = eventType;
        return {"codepoint": codepoint, "modifier": (modValue - 1), "eventType": eventType};
    }
    return None;
}

def matchesKittySequence(data: str, expectedCodepoint: float, expectedModifier: float) -> bool {
    parsed = parseKittySequence(data);
    if not parsed {
        return False;
    }
    actualMod = float(int((parsed["modifier"] as float)) & int(float(~int(LOCK_MASK))));
    expectedMod = float(int(expectedModifier) & int(float(~int(LOCK_MASK))));
    if (actualMod != expectedMod) {
        return False;
    }
    normalizedCodepoint: float = float(normalizeShiftedLetterIdentityCodepoint(normalizeKittyFunctionalCodepoint((parsed["codepoint"] as float)), (parsed["modifier"] as float)));
    normalizedExpectedCodepoint: float = float(normalizeShiftedLetterIdentityCodepoint(normalizeKittyFunctionalCodepoint(expectedCodepoint), expectedModifier));
    if (normalizedCodepoint == normalizedExpectedCodepoint) {
        return True;
    }
    if (((parsed["baseLayoutKey"] as float | None) != None) and ((parsed["baseLayoutKey"] as float | None) == expectedCodepoint)) {
        cp: float = float(normalizedCodepoint);
        isLatinLetter: float = float(((cp >= 97) and (cp <= 122)));
        isKnownSymbol = SYMBOL_KEYS.has(String.fromCharCode(cp));
        if (not isLatinLetter and not isKnownSymbol) {
            return True;
        }
    }
    return False;
}

def parseModifyOtherKeysSequence(data: str) -> any | None {
    match_j = search(r"^\x1b\[27;(\d+);(\d+)~$", data);
    if not match_j {
        return None;
    }
    modValue = int((match_j.group(1) as any), 10);
    codepoint = int((match_j.group(2) as any), 10);
    return {"codepoint": codepoint, "modifier": (modValue - 1)};
}

def matchesModifyOtherKeys(data: str, expectedKeycode: float, expectedModifier: float) -> bool {
    parsed = parseModifyOtherKeysSequence(data);
    if not parsed {
        return False;
    }
    return (((parsed["codepoint"] as float) == expectedKeycode) and ((parsed["modifier"] as float) == expectedModifier));
}

def isWindowsTerminalSession() -> bool {
    return (((Boolean(environ.get("WT_SESSION")) and not environ.get("SSH_CONNECTION")) and not environ.get("SSH_CLIENT")) and not environ.get("SSH_TTY"));
}

def matchesRawBackspace(data: str, expectedModifier: float) -> bool {
    if (data == "") {
        return (expectedModifier == 0);
    }
    if (data != "\b") {
        return False;
    }
    return ((expectedModifier == MODIFIERS.ctrl) if isWindowsTerminalSession() else (expectedModifier == 0));
}

def rawCtrlChar(key: str) -> str | None {
    char: str = key.lower();
    code = ord(char[0]);
    if ((((((code >= 97) and (code <= 122)) or (char == "[")) or (char == "\\")) or (char == "]")) or (char == "_")) {
        return String.fromCharCode(float(int(code) & int(31)));
    }
    if (char == "-") {
        return String.fromCharCode(31);
    }
    return None;
}

def isDigitKey(key: str) -> bool {
    return ((key >= "0") and (key <= "9"));
}

def matchesPrintableModifyOtherKeys(data: str, expectedKeycode: float, expectedModifier: float) -> bool {
    if (expectedModifier == 0) {
        return False;
    }
    parsed = parseModifyOtherKeysSequence(data);
    if (not parsed or ((parsed["modifier"] as float) != expectedModifier)) {
        return False;
    }
    return (normalizeShiftedLetterIdentityCodepoint((parsed["codepoint"] as float), (parsed["modifier"] as float)) == normalizeShiftedLetterIdentityCodepoint(expectedKeycode, expectedModifier));
}

def formatKeyNameWithModifiers(keyName: str, modifier: float) -> str | None {
    mods: list[str] = [];
    effectiveMod = float(int(modifier) & int(float(~int(LOCK_MASK))));
    supportedModifierMask = float(int(float(int(float(int(MODIFIERS.shift) | int(MODIFIERS.ctrl))) | int(MODIFIERS.alt))) | int(MODIFIERS.super));
    if (float(int(effectiveMod) & int(float(~int(supportedModifierMask)))) != 0) {
        return None;
    }
    if float(int(effectiveMod) & int(MODIFIERS.shift)) {
        mods.append("shift");
    }
    if float(int(effectiveMod) & int(MODIFIERS.ctrl)) {
        mods.append("ctrl");
    }
    if float(int(effectiveMod) & int(MODIFIERS.alt)) {
        mods.append("alt");
    }
    if float(int(effectiveMod) & int(MODIFIERS.super)) {
        mods.append("super");
    }
    return (f"{"+".join(mods)}+{keyName}" if (len(mods) > 0) else keyName);
}

def parseKeyId(keyId: str) -> dict[str, str | bool] | None {
    parts = keyId.lower().split("+");
    key = parts[(len(parts) - 1)];
    if not key {
        return None;
    }
    return {"key": key, "ctrl": ("ctrl" in parts), "shift": ("shift" in parts), "alt": ("alt" in parts), "super": ("super" in parts)};
}

def formatParsedKey(codepoint: float, modifier: float, baseLayoutKey: float) -> str | None {
    normalizedCodepoint: float = float(normalizeKittyFunctionalCodepoint(codepoint));
    identityCodepoint: float = float(normalizeShiftedLetterIdentityCodepoint(normalizedCodepoint, modifier));
    isLatinLetter: float = float(((identityCodepoint >= 97) and (identityCodepoint <= 122)));
    isDigit: float = float(((identityCodepoint >= 48) and (identityCodepoint <= 57)));
    isKnownSymbol = SYMBOL_KEYS.has(String.fromCharCode(identityCodepoint));
    effectiveCodepoint = (identityCodepoint if ((isLatinLetter or isDigit) or isKnownSymbol) else ((lambda (_jx_null1: any) -> any { return (_jx_null1 if _jx_null1 is not None else identityCodepoint); })(baseLayoutKey)));
    keyName: str | None;
    if (effectiveCodepoint == CODEPOINTS.escape) {
        keyName = "escape";
    }
    elif (effectiveCodepoint == CODEPOINTS.tab) {
        keyName = "tab";
    }
    elif ((effectiveCodepoint == CODEPOINTS.enter) or (effectiveCodepoint == CODEPOINTS.kpEnter)) {
        keyName = "enter";
    }
    elif (effectiveCodepoint == CODEPOINTS.space) {
        keyName = "space";
    }
    elif (effectiveCodepoint == CODEPOINTS.backspace) {
        keyName = "backspace";
    }
    elif (effectiveCodepoint == FUNCTIONAL_CODEPOINTS.delete) {
        keyName = "delete";
    }
    elif (effectiveCodepoint == FUNCTIONAL_CODEPOINTS.insert) {
        keyName = "insert";
    }
    elif (effectiveCodepoint == FUNCTIONAL_CODEPOINTS.home) {
        keyName = "home";
    }
    elif (effectiveCodepoint == FUNCTIONAL_CODEPOINTS.end) {
        keyName = "end";
    }
    elif (effectiveCodepoint == FUNCTIONAL_CODEPOINTS.pageUp) {
        keyName = "pageUp";
    }
    elif (effectiveCodepoint == FUNCTIONAL_CODEPOINTS.pageDown) {
        keyName = "pageDown";
    }
    elif (effectiveCodepoint == ARROW_CODEPOINTS.up) {
        keyName = "up";
    }
    elif (effectiveCodepoint == ARROW_CODEPOINTS.down) {
        keyName = "down";
    }
    elif (effectiveCodepoint == ARROW_CODEPOINTS.left) {
        keyName = "left";
    }
    elif (effectiveCodepoint == ARROW_CODEPOINTS.right) {
        keyName = "right";
    }
    elif ((effectiveCodepoint >= 48) and (effectiveCodepoint <= 57)) {
        keyName = String.fromCharCode(effectiveCodepoint);
    }
    elif ((effectiveCodepoint >= 97) and (effectiveCodepoint <= 122)) {
        keyName = String.fromCharCode(effectiveCodepoint);
    }
    elif SYMBOL_KEYS.has(String.fromCharCode(effectiveCodepoint)) {
        keyName = String.fromCharCode(effectiveCodepoint);
    }
    if not keyName {
        return None;
    }
    return formatKeyNameWithModifiers(keyName, modifier);
}

def:pub parseKey(data: str) -> str | None {
    kitty = parseKittySequence(data);
    if kitty {
        return formatParsedKey((kitty["codepoint"] as float), (kitty["modifier"] as float), (kitty["baseLayoutKey"] as float | None));
    }
    modifyOtherKeys = parseModifyOtherKeysSequence(data);
    if modifyOtherKeys {
        return formatParsedKey((modifyOtherKeys["codepoint"] as float), (modifyOtherKeys["modifier"] as float));
    }
    if _kittyProtocolActive {
        if ((data == "\u001b\r") or (data == "\n")) {
            return "shift+enter";
        }
    }
    legacySequenceKeyId = LEGACY_SEQUENCE_KEY_IDS[data];
    if legacySequenceKeyId {
        return (legacySequenceKeyId as str | None);
    }
    if (data == "\u001b") {
        return "escape";
    }
    if (data == "\u001c") {
        return "ctrl+\\";
    }
    if (data == "\u001d") {
        return "ctrl+]";
    }
    if (data == "\u001f") {
        return "ctrl+-";
    }
    if (data == "\u001b\u001b") {
        return "ctrl+alt+[";
    }
    if (data == "\u001b\u001c") {
        return "ctrl+alt+\\";
    }
    if (data == "\u001b\u001d") {
        return "ctrl+alt+]";
    }
    if (data == "\u001b\u001f") {
        return "ctrl+alt+-";
    }
    if (data == "\t") {
        return "tab";
    }
    if (((data == "\r") or (not _kittyProtocolActive and (data == "\n"))) or (data == "\u001bOM")) {
        return "enter";
    }
    if (data == "\u0000") {
        return "ctrl+space";
    }
    if (data == " ") {
        return "space";
    }
    if (data == "") {
        return "backspace";
    }
    if (data == "\b") {
        return ("ctrl+backspace" if isWindowsTerminalSession() else "backspace");
    }
    if (data == "\u001b[Z") {
        return "shift+tab";
    }
    if (not _kittyProtocolActive and (data == "\u001b\r")) {
        return "alt+enter";
    }
    if (not _kittyProtocolActive and (data == "\u001b ")) {
        return "alt+space";
    }
    if ((data == "\u001b") or (data == "\u001b\b")) {
        return "alt+backspace";
    }
    if (not _kittyProtocolActive and (data == "\u001bB")) {
        return "alt+left";
    }
    if (not _kittyProtocolActive and (data == "\u001bF")) {
        return "alt+right";
    }
    if ((not _kittyProtocolActive and (len(data) == 2)) and (data[0] == "\u001b")) {
        code = ord(data[1]);
        if ((code >= 1) and (code <= 26)) {
            return f"ctrl+alt+{String.fromCharCode((code + 96))}";
        }
        key = String.fromCharCode(code);
        if ((((code >= 97) and (code <= 122)) or ((code >= 48) and (code <= 57))) or SYMBOL_KEYS.has(key)) {
            return f"alt+{key}";
        }
    }
    if (data == "\u001b[A") {
        return "up";
    }
    if (data == "\u001b[B") {
        return "down";
    }
    if (data == "\u001b[C") {
        return "right";
    }
    if (data == "\u001b[D") {
        return "left";
    }
    if ((data == "\u001b[H") or (data == "\u001bOH")) {
        return "home";
    }
    if ((data == "\u001b[F") or (data == "\u001bOF")) {
        return "end";
    }
    if (data == "\u001b[3~") {
        return "delete";
    }
    if (data == "\u001b[5~") {
        return "pageUp";
    }
    if (data == "\u001b[6~") {
        return "pageDown";
    }
    if (len(data) == 1) {
        code = ord(data[0]);
        if ((code >= 1) and (code <= 26)) {
            return f"ctrl+{String.fromCharCode((code + 96))}";
        }
        if ((code >= 32) and (code <= 126)) {
            return data;
        }
    }
    return None;
}

glob KITTY_CSI_U_REGEX = compile(r"^\x1b\[(\d+)(?::(\d*))?(?::(\d+))?(?:;(\d+))?(?::(\d+))?u$");

glob KITTY_PRINTABLE_ALLOWED_MODIFIERS = float(int(MODIFIERS.shift) | int(LOCK_MASK));

def:pub decodeKittyPrintable(data: str) -> str | None {
    match_j = search(KITTY_CSI_U_REGEX, data);
    if not match_j {
        return None;
    }
    codepoint = int(((lambda (_jx_null2: any) -> any { return (_jx_null2 if _jx_null2 is not None else ""); })(match_j.group(1))), 10);
    if not Number.isFinite(codepoint) {
        return None;
    }
    shiftedKey = (int(match_j.group(2), 10) if (match_j.group(2) and (len(match_j.group(2)) > 0)) else None);
    modValue = (int(match_j.group(4), 10) if match_j.group(4) else 1);
    modifier = ((modValue - 1) if Number.isFinite(modValue) else 0);
    if (float(int(modifier) & int(float(~int(KITTY_PRINTABLE_ALLOWED_MODIFIERS)))) != 0) {
        return None;
    }
    if float(int(modifier) & int(float(int(MODIFIERS.alt) | int(MODIFIERS.ctrl)))) {
        return None;
    }
    effectiveCodepoint = codepoint;
    if (float(int(modifier) & int(MODIFIERS.shift)) and isinstance(shiftedKey, (int, float))) {
        effectiveCodepoint = shiftedKey;
    }
    effectiveCodepoint = normalizeKittyFunctionalCodepoint(effectiveCodepoint);
    if (not Number.isFinite(effectiveCodepoint) or (effectiveCodepoint < 32)) {
        return None;
    }
    try {
        return String.fromCodePoint(effectiveCodepoint);
    }
    except Exception {
        return None;
    }
}

def decodeModifyOtherKeysPrintable(data: str) -> str | None {
    parsed = parseModifyOtherKeysSequence(data);
    if not parsed {
        return None;
    }
    modifier = float(int((parsed["modifier"] as float)) & int(float(~int(LOCK_MASK))));
    if (float(int(modifier) & int(float(~int(MODIFIERS.shift)))) != 0) {
        return None;
    }
    if (not Number.isFinite((parsed["codepoint"] as float)) or ((parsed["codepoint"] as float) < 32)) {
        return None;
    }
    try {
        return String.fromCodePoint((parsed["codepoint"] as float));
    }
    except Exception {
        return None;
    }
}

def:pub decodePrintableKey(data: str) -> str | None {
    return ((lambda (_jx_null3: any) -> any { return (_jx_null3 if _jx_null3 is not None else decodeModifyOtherKeysPrintable(data)); })(decodeKittyPrintable(data)));
}

# ===== JS2JAC UNCONVERTED (1 decl(s), needs LLM) =====
# JS2JAC-HOLE[E7200] Declaration produced no output:
# | export function matchesKey(data: string, keyId: KeyId): boolean {
# | 	const parsed = parseKeyId(keyId);
# | 	if (!parsed) return false;
# | 
# | 	const { key, ctrl, shift, alt, super: superModifier } = parsed;
# | 	let modifier = 0;
# | 	if (shift) modifier |= MODIFIERS.shift;
# | 	if (alt) modifier |= MODIFIERS.alt;
# | 	if (ctrl) modifier |= MODIFIERS.ctrl;
# | 	if (superModifier) modifier |= MODIFIERS.super;
# | 
# | 	switch (key) {
# | 		case "escape":
# | 		case "esc":
# | 			if (modifier !== 0) return false;
# | 			return (
# | 				data === "\x1b" ||
# | 				matchesKittySequence(data, CODEPOINTS.escape, 0) ||
# | 				matchesModifyOtherKeys(data, CODEPOINTS.escape, 0)
# | 			);
# | 
# | 		case "space":
# | 			if (!_kittyProtocolActive) {
# | 				if (modifier === MODIFIERS.ctrl && data === "\x00") {
# | 					return true;
# | 				}
# | 				if (modifier === MODIFIERS.alt && data === "\x1b ") {
# | 					return true;
# | 				}
# | 			}
# | 			if (modifier === 0) {
# | 				return (
# | 					data === " " ||
# | 					matchesKittySequence(data, CODEPOINTS.space, 0) ||
# | 					matchesModifyOtherKeys(data, CODEPOINTS.space, 0)
# | 				);
# | 			}
# | 			return (
# | 				matchesKittySequence(data, CODEPOINTS.space, modifier) ||
# | 				matchesModifyOtherKeys(data, CODEPOINTS.space, modifier)
# | 			);
# | 
# | 		case "tab":
# | 			if (modifier === MODIFIERS.shift) {
# | 				return (
# | 					data === "\x1b[Z" ||
# | 					matchesKittySequence(data, CODEPOINTS.tab, MODIFIERS.shift) ||
# | 					matchesModifyOtherKeys(data, CODEPOINTS.tab, MODIFIERS.shift)
# | 				);
# | 			}
# | 			if (modifier === 0) {
# | 				return data === "\t" || matchesKittySequence(data, CODEPOINTS.tab, 0);
# | 			}
# | 			return (
# | 				matchesKittySequence(data, CODEPOINTS.tab, modifier) ||
# | 				matchesModifyOtherKeys(data, CODEPOINTS.tab, modifier)
# | 			);
# | 
# | 		case "enter":
# | 		case "return":
# | 			if (modifier === MODIFIERS.shift) {
# | 				// CSI u sequences (standard Kitty protocol)
# | 				if (
# | 					matchesKittySequence(data, CODEPOINTS.enter, MODIFIERS.shift) ||
# | 					matchesKittySequence(data, CODEPOINTS.kpEnter, MODIFIERS.shift)
# | 				) {
# | 					return true;
# | 				}
# | 				// xterm modifyOtherKeys format (fallback when Kitty protocol not enabled)
# | 				if (matchesModifyOtherKeys(data, CODEPOINTS.enter, MODIFIERS.shift)) {
# | 					return true;
# | 				}
# | 				// When Kitty protocol is active, legacy sequences are custom terminal mappings
# | 				// \x1b\r = Kitty's "map shift+enter send_text all \e\r"
# | 				// \n = Ghostty's "keybind = shift+enter=text:\n"
# | 				if (_kittyProtocolActive) {
# | 					return data === "\x1b\r" || data === "\n";
# | 				}
# | 				return false;
# | 			}
# | 			if (modifier === MODIFIERS.alt) {
# | 				// CSI u sequences (standard Kitty protocol)
# | 				if (
# | 					matchesKittySequence(data, CODEPOINTS.enter, MODIFIERS.alt) ||
# | 					matchesKittySequence(data, CODEPOINTS.kpEnter, MODIFIERS.alt)
# | 				) {
# | 					return true;
# | 				}
# | 				// xterm modifyOtherKeys format (fallback when Kitty protocol not enabled)
# | 				if (matchesModifyOtherKeys(data, CODEPOINTS.enter, MODIFIERS.alt)) {
# | 					return true;
# | 				}
# | 				// \x1b\r is alt+enter only in legacy mode (no Kitty protocol)
# | 				// When Kitty protocol is active, alt+enter comes as CSI u sequence
# | 				if (!_kittyProtocolActive) {
# | 					return data === "\x1b\r";
# | 				}
# | 				return false;
# | 			}
# | 			if (modifier === 0) {
# | 				return (
# | 					data === "\r" ||
# | 					(!_kittyProtocolActive && data === "\n") ||
# | 					data === "\x1bOM" || // SS3 M (numpad enter in some terminals)
# | 					matchesKittySequence(data, CODEPOINTS.enter, 0) ||
# | 					matchesKittySequence(data, CODEPOINTS.kpEnter, 0)
# | 				);
# | 			}
# | 			return (
# | 				matchesKittySequence(data, CODEPOINTS.enter, modifier) ||
# | 				matchesKittySequence(data, CODEPOINTS.kpEnter, modifier) ||
# | 				matchesModifyOtherKeys(data, CODEPOINTS.enter, modifier)
# | 			);
# | 
# | 		case "backspace":
# | 			if (modifier === MODIFIERS.alt) {
# | 				if (data === "\x1b\x7f" || data === "\x1b\b") {
# | 					return true;
# | 				}
# | 				return (
# | 					matchesKittySequence(data, CODEPOINTS.backspace, MODIFIERS.alt) ||
# | 					matchesModifyOtherKeys(data, CODEPOINTS.backspace, MODIFIERS.alt)
# | 				);
# | 			}
# | 			if (modifier === MODIFIERS.ctrl) {
# | 				// Legacy raw 0x08 is ambiguous: it can be Ctrl+Backspace on Windows
# | 				// Terminal or plain Backspace on other terminals, while also
# | 				// overlapping with Ctrl+H.
# | 				if (matchesRawBackspace(data, MODIFIERS.ctrl)) return true;
# | 				return (
# | 					matchesKittySequence(data, CODEPOINTS.backspace, MODIFIERS.ctrl) ||
# | 					matchesModifyOtherKeys(data, CODEPOINTS.backspace, MODIFIERS.ctrl)
# | 				);
# | 			}
# | 			if (modifier === 0) {
# | 				return (
# | 					matchesRawBackspace(data, 0) ||
# | 					matchesKittySequence(data, CODEPOINTS.backspace, 0) ||
# | 					matchesModifyOtherKeys(data, CODEPOINTS.backspace, 0)
# | 				);
# | 			}
# | 			return (
# | 				matchesKittySequence(data, CODEPOINTS.backspace, modifier) ||
# | 				matchesModifyOtherKeys(data, CODEPOINTS.backspace, modifier)
# | 			);
# | 
# | 		case "insert":
# | 			if (modifier === 0) {
# | 				return (
# | 					matchesLegacySequence(data, LEGACY_KEY_SEQUENCES.insert) ||
# | 					matchesKittySequence(data, FUNCTIONAL_CODEPOINTS.insert, 0)
# | 				);
# | 			}
# | 			if (matchesLegacyModifierSequence(data, "insert", modifier)) {
# | 				return true;
# | 			}
# | 			return matchesKittySequence(data, FUNCTIONAL_CODEPOINTS.insert, modifier);
# | 
# | 		case "delete":
# | 			if (modifier === 0) {
# | 				return (
# | 					matchesLegacySequence(data, LEGACY_KEY_SEQUENCES.delete) ||
# | 					matchesKittySequence(data, FUNCTIONAL_CODEPOINTS.delete, 0)
# | 				);
# | 			}
# | 			if (matchesLegacyModifierSequence(data, "delete", modifier)) {
# | 				return true;
# | 			}
# | 			return matchesKittySequence(data, FUNCTIONAL_CODEPOINTS.delete, modifier);
# | 
# | 		case "clear":
# | 			if (modifier === 0) {
# | 				return matchesLegacySequence(data, LEGACY_KEY_SEQUENCES.clear);
# | 			}
# | 			return matchesLegacyModifierSequence(data, "clear", modifier);
# | 
# | 		case "home":
# | 			if (modifier === 0) {
# | 				return (
# | 					matchesLegacySequence(data, LEGACY_KEY_SEQUENCES.home) ||
# | 					matchesKittySequence(data, FUNCTIONAL_CODEPOINTS.home, 0)
# | 				);
# | 			}
# | 			if (matchesLegacyModifierSequence(data, "home", modifier)) {
# | 				return true;
# | 			}
# | 			return matchesKittySequence(data, FUNCTIONAL_CODEPOINTS.home, modifier);
# | 
# | 		case "end":
# | 			if (modifier === 0) {
# | 				return (
# | 					matchesLegacySequence(data, LEGACY_KEY_SEQUENCES.end) ||
# | 					matchesKittySequence(data, FUNCTIONAL_CODEPOINTS.end, 0)
# | 				);
# | 			}
# | 			if (matchesLegacyModifierSequence(data, "end", modifier)) {
# | 				return true;
# | 			}
# | 			return matchesKittySequence(data, FUNCTIONAL_CODEPOINTS.end, modifier);
# | 
# | 		case "pageup":
# | 			if (modifier === 0) {
# | 				return (
# | 					matchesLegacySequence(data, LEGACY_KEY_SEQUENCES.pageUp) ||
# | 					matchesKittySequence(data, FUNCTIONAL_CODEPOINTS.pageUp, 0)
# | 				);
# | 			}
# | 			if (matchesLegacyModifierSequence(data, "pageUp", modifier)) {
# | 				return true;
# | 			}
# | 			return matchesKittySequence(data, FUNCTIONAL_CODEPOINTS.pageUp, modifier);
# | 
# | 		case "pagedown":
# | 			if (modifier === 0) {
# | 				return (
# | 					matchesLegacySequence(data, LEGACY_KEY_SEQUENCES.pageDown) ||
# | 					matchesKittySequence(data, FUNCTIONAL_CODEPOINTS.pageDown, 0)
# | 				);
# | 			}
# | 			if (matchesLegacyModifierSequence(data, "pageDown", modifier)) {
# | 				return true;
# | 			}
# | 			return matchesKittySequence(data, FUNCTIONAL_CODEPOINTS.pageDown, modifier);
# | 
# | 		case "up":
# | 			if (modifier === MODIFIERS.alt) {
# | 				return data === "\x1bp" || matchesKittySequence(data, ARROW_CODEPOINTS.up, MODIFIERS.alt);
# | 			}
# | 			if (modifier === 0) {
# | 				return (
# | 					matchesLegacySequence(data, LEGACY_KEY_SEQUENCES.up) ||
# | 					matchesKittySequence(data, ARROW_CODEPOINTS.up, 0)
# | 				);
# | 			}
# | 			if (matchesLegacyModifierSequence(data, "up", modifier)) {
# | 				return true;
# | 			}
# | 			return matchesKittySequence(data, ARROW_CODEPOINTS.up, modifier);
# | 
# | 		case "down":
# | 			if (modifier === MODIFIERS.alt) {
# | 				return data === "\x1bn" || matchesKittySequence(data, ARROW_CODEPOINTS.down, MODIFIERS.alt);
# | 			}
# | 			if (modifier === 0) {
# | 				return (
# | 					matchesLegacySequence(data, LEGACY_KEY_SEQUENCES.down) ||
# | 					matchesKittySequence(data, ARROW_CODEPOINTS.down, 0)
# | 				);
# | 			}
# | 			if (matchesLegacyModifierSequence(data, "down", modifier)) {
# | 				return true;
# | 			}
# | 			return matchesKittySequence(data, ARROW_CODEPOINTS.down, modifier);
# | 
# | 		case "left":
# | 			if (modifier === MODIFIERS.alt) {
# | 				return (
# | 					data === "\x1b[1;3D" ||
# | 					(!_kittyProtocolActive && data === "\x1bB") ||
# | 					data === "\x1bb" ||
# | 					matchesKittySequence(data, ARROW_CODEPOINTS.left, MODIFIERS.alt)
# | 				);
# | 			}
# | 			if (modifier === MODIFIERS.ctrl) {
# | 				return (
# | 					data === "\x1b[1;5D" ||
# | 					matchesLegacyModifierSequence(data, "left", MODIFIERS.ctrl) ||
# | 					matchesKittySequence(data, ARROW_CODEPOINTS.left, MODIFIERS.ctrl)
# | 				);
# | 			}
# | 			if (modifier === 0) {
# | 				return (
# | 					matchesLegacySequence(data, LEGACY_KEY_SEQUENCES.left) ||
# | 					matchesKittySequence(data, ARROW_CODEPOINTS.left, 0)
# | 				);
# | 			}
# | 			if (matchesLegacyModifierSequence(data, "left", modifier)) {
# | 				return true;
# | 			}
# | 			return matchesKittySequence(data, ARROW_CODEPOINTS.left, modifier);
# | 
# | 		case "right":
# | 			if (modifier === MODIFIERS.alt) {
# | 				return (
# | 					data === "\x1b[1;3C" ||
# | 					(!_kittyProtocolActive && data === "\x1bF") ||
# | 					data === "\x1bf" ||
# | 					matchesKittySequence(data, ARROW_CODEPOINTS.right, MODIFIERS.alt)
# | 				);
# | 			}
# | 			if (modifier === MODIFIERS.ctrl) {
# | 				return (
# | 					data === "\x1b[1;5C" ||
# | 					matchesLegacyModifierSequence(data, "right", MODIFIERS.ctrl) ||
# | 					matchesKittySequence(data, ARROW_CODEPOINTS.right, MODIFIERS.ctrl)
# | 				);
# | 			}
# | 			if (modifier === 0) {
# | 				return (
# | 					matchesLegacySequence(data, LEGACY_KEY_SEQUENCES.right) ||
# | 					matchesKittySequence(data, ARROW_CODEPOINTS.right, 0)
# | 				);
# | 			}
# | 			if (matchesLegacyModifierSequence(data, "right", modifier)) {
# | 				return true;
# | 			}
# | 			return matchesKittySequence(data, ARROW_CODEPOINTS.right, modifier);
# | 
# | 		case "f1":
# | 		case "f2":
# | 		case "f3":
# | 		case "f4":
# | 		case "f5":
# | 		case "f6":
# | 		case "f7":
# | 		case "f8":
# | 		case "f9":
# | 		case "f10":
# | 		case "f11":
# | 		case "f12": {
# | 			if (modifier !== 0) {
# | 				return false;
# | 			}
# | 			const functionKey = key as keyof typeof LEGACY_KEY_SEQUENCES;
# | 			return matchesLegacySequence(data, LEGACY_KEY_SEQUENCES[functionKey]);
# | 		}
# | 	}
# | 
# | 	// Handle single letter/digit keys and symbols
# | 	if (key.length === 1 && ((key >= "a" && key <= "z") || isDigitKey(key) || SYMBOL_KEYS.has(key))) {
# | 		const codepoint = key.charCodeAt(0);
# | 		const rawCtrl = rawCtrlChar(key);
# | 		const isLetter = key >= "a" && key <= "z";
# | 		const isDigit = isDigitKey(key);
# | 
# | 		if (modifier === MODIFIERS.ctrl + MODIFIERS.alt && !_kittyProtocolActive && rawCtrl) {
# | 			// Legacy: ctrl+alt+key is ESC followed by the control character.
# | 			// If that legacy form does not match, continue so CSI-u and
# | 			// modifyOtherKeys sequences from tmux can still be recognized.
# | 			if (data === `\x1b${rawCtrl}`) return true;
# | 		}
# | 
# | 		if (modifier === MODIFIERS.alt && !_kittyProtocolActive && (isLetter || isDigit || SYMBOL_KEYS.has(key))) {
# | 			// Legacy: alt+printable key is ESC followed by the key
# | 			if (data === `\x1b${key}`) return true;
# | 		}
# | 
# | 		if (modifier === MODIFIERS.ctrl) {
# | 			// Legacy: ctrl+key sends the control character
# | 			if (rawCtrl && data === rawCtrl) return true;
# | 			return (
# | 				matchesKittySequence(data, codepoint, MODIFIERS.ctrl) ||
# | 				matchesPrintableModifyOtherKeys(data, codepoint, MODIFIERS.ctrl)
# | 			);
# | 		}
# | 
# | 		if (modifier === MODIFIERS.shift + MODIFIERS.ctrl) {
# | 			return (
# | 				matchesKittySequence(data, codepoint, MODIFIERS.shift + MODIFIERS.ctrl) ||
# | 				matchesPrintableModifyOtherKeys(data, codepoint, MODIFIERS.shift + MODIFIERS.ctrl)
# | 			);
# | 		}
# | 
# | 		if (modifier === MODIFIERS.shift) {
# | 			// Legacy: shift+letter produces uppercase
# | 			if (isLetter && data === key.toUpperCase()) return true;
# | 			return (
# | 				matchesKittySequence(data, codepoint, MODIFIERS.shift) ||
# | 				matchesPrintableModifyOtherKeys(data, codepoint, MODIFIERS.shift)
# | 			);
# | 		}
# | 
# | 		if (modifier !== 0) {
# | 			return (
# | 				matchesKittySequence(data, codepoint, modifier) ||
# | 				matchesPrintableModifyOtherKeys(data, codepoint, modifier)
# | 			);
# | 		}
# | 
# | 		// Check both raw char and Kitty sequence (needed for release events)
# | 		return data === key || matchesKittySequence(data, codepoint, 0);
# | 	}
# | 
# | 	return false;
# | }
