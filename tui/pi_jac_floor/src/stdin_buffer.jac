# interop import: events { EventEmitter }  -> Jac-native adapter below
import from re { search }
import from .input_support { EventEmitter, set_timeout, clear_timeout, is_buffer }

glob ESC = "\u001b";

glob BRACKETED_PASTE_START = "\u001b[200~";

glob BRACKETED_PASTE_END = "\u001b[201~";

def isCompleteSequence(data: str) -> any {
    if not data.startswith(ESC) {
        return "not-escape";
    }
    if (len(data) == 1) {
        return "incomplete";
    }
    afterEsc = data[1:];
    if afterEsc.startswith("[") {
        if afterEsc.startswith("[M") {
            return ("complete" if (len(data) >= 6) else "incomplete");
        }
        return isCompleteCsiSequence(data);
    }
    if afterEsc.startswith("]") {
        return isCompleteOscSequence(data);
    }
    if afterEsc.startswith("P") {
        return isCompleteDcsSequence(data);
    }
    if afterEsc.startswith("_") {
        return isCompleteApcSequence(data);
    }
    if afterEsc.startswith("O") {
        return ("complete" if (len(afterEsc) >= 2) else "incomplete");
    }
    if (len(afterEsc) == 1) {
        return "complete";
    }
    return "complete";
}

def isCompleteCsiSequence(data: str) -> any {
    if not data.startswith(f"{ESC}[") {
        return "complete";
    }
    if (len(data) < 3) {
        return "incomplete";
    }
    payload = data[2:];
    lastChar = payload[(len(payload) - 1)];
    lastCharCode = ord(lastChar[0]);
    if ((lastCharCode >= 64) and (lastCharCode <= 126)) {
        if payload.startswith("<") {
            mouseMatch = (search(r"^<\d+;\d+;\d+[Mm]$", payload) is not None);
            if mouseMatch {
                return "complete";
            }
            if ((lastChar == "M") or (lastChar == "m")) {
                parts = payload[1:-1].split(";");
                if ((len(parts) == 3) and all((search(r"^\d+$", p) is not None) for p in parts)) {
                    return "complete";
                }
            }
            return "incomplete";
        }
        return "complete";
    }
    return "incomplete";
}

def isCompleteOscSequence(data: str) -> any {
    if not data.startswith(f"{ESC}]") {
        return "complete";
    }
    if (data.endswith(f"{ESC}\\\\") or data.endswith("\u0007")) {
        return "complete";
    }
    return "incomplete";
}

def isCompleteDcsSequence(data: str) -> any {
    if not data.startswith(f"{ESC}P") {
        return "complete";
    }
    if data.endswith(f"{ESC}\\\\") {
        return "complete";
    }
    return "incomplete";
}

def isCompleteApcSequence(data: str) -> any {
    if not data.startswith(f"{ESC}_") {
        return "complete";
    }
    if data.endswith(f"{ESC}\\\\") {
        return "complete";
    }
    return "incomplete";
}

def parseUnmodifiedKittyPrintableCodepoint(sequence: str) -> float | None {
    match_j = search(r"^\x1b\[(\d+)(?::\d*)?(?::\d+)?u$", sequence);
    if not match_j {
        return None;
    }
    codepoint = int((match_j.group(1) as any), 10);
    return (codepoint if (codepoint >= 32) else None);
}

def extractCompleteSequences(buffer: str) -> dict[str, list[str] | str] {
    sequences: list[str] = [];
    pos = 0;
    while (pos < len(buffer)) {
        remaining = buffer[pos:];
        if remaining.startswith(ESC) {
            seqEnd = 1;
            while (seqEnd <= len(remaining)) {
                candidate = remaining[0:seqEnd];
                status = isCompleteSequence(candidate);
                if (status == "complete") {
                    if (candidate == "\u001b\u001b") {
                        nextChar = remaining[seqEnd];
                        if (((((nextChar == "[") or (nextChar == "]")) or (nextChar == "O")) or (nextChar == "P")) or (nextChar == "_")) {
                            sequences.append(ESC);
                            pos += 1;
                            break;
                        }
                    }
                    sequences.append(candidate);
                    pos += seqEnd;
                    break;
                }
                elif (status == "incomplete") {
                    seqEnd += 1;
                }
                else {
                    sequences.append(candidate);
                    pos += seqEnd;
                    break;
                }
            }
            if (seqEnd > len(remaining)) {
                return {"sequences": sequences, "remainder": remaining};
            }
        }
        else {
            sequences.append((remaining[0] as any));
            pos += 1;
        }
    }
    return {"sequences": sequences, "remainder": ""};
}

obj:pub StdinBuffer(EventEmitter) {
    has timeoutMs: float = 10;
    has pendingKittyPrintableCodepoint: float | None = None;
    has buffer: str = "";
    has timeout: any | None = None;
    has pasteMode: bool = False;
    has pasteBuffer: str = "";
    def __init__(options: any = {}) -> None {
        # NOTE(port): this Jac runtime cannot lower a zero-arg super() call, so
        # seed the inherited EventEmitter state directly rather than via super().
        # A custom __init__ also suppresses Jac's has-default application, so all
        # mutable/instance fields are seeded explicitly (same pattern as Box).
        self.listeners = {};
        tmo = (options.get("timeout") if isinstance(options, dict) else None);
        self.timeoutMs = (tmo if (tmo is not None) else 10);
        self.pendingKittyPrintableCodepoint = None;
        self.buffer = "";
        self.timeout = None;
        self.pasteMode = False;
        self.pasteBuffer = "";
    }
    override def process(data: str | any) -> None {
        if self.timeout {
            clear_timeout(self.timeout);
            self.timeout = None;
        }
        str_j: str;
        if is_buffer(data) {
            if ((len(data) == 1) and ((data[0] as any) > 127)) {
                byte = ((data[0] as any) - 128);
                str_j = f"{ESC}{chr(int(byte))}";
            }
            else {
                str_j = str(data);
            }
        }
        else {
            str_j = data;
        }
        if ((len(str_j) == 0) and (len(self.buffer) == 0)) {
            self.emitDataSequence("");
            return;
        }
        self.buffer += str_j;
        if self.pasteMode {
            self.pasteBuffer += self.buffer;
            self.buffer = "";
            endIndex = (-1 if BRACKETED_PASTE_END not in self.pasteBuffer else self.pasteBuffer.index(BRACKETED_PASTE_END));
            if (endIndex != -1) {
                pastedContent = self.pasteBuffer[0:endIndex];
                remaining = self.pasteBuffer[(endIndex + len(BRACKETED_PASTE_END)):];
                self.pasteMode = False;
                self.pasteBuffer = "";
                self.pendingKittyPrintableCodepoint = None;
                self.emit("paste", pastedContent);
                if (len(remaining) > 0) {
                    self.process(remaining);
                }
            }
            return;
        }
        startIndex = (-1 if BRACKETED_PASTE_START not in self.buffer else self.buffer.index(BRACKETED_PASTE_START));
        if (startIndex != -1) {
            if (startIndex > 0) {
                beforePaste = self.buffer[0:startIndex];
                result = extractCompleteSequences(beforePaste);
                for sequence in (result["sequences"] as list[str]) {
                    self.emitDataSequence(sequence);
                }
            }
            self.pendingKittyPrintableCodepoint = None;
            self.buffer = self.buffer[(startIndex + len(BRACKETED_PASTE_START)):];
            self.pasteMode = True;
            self.pasteBuffer = self.buffer;
            self.buffer = "";
            endIndex = (-1 if BRACKETED_PASTE_END not in self.pasteBuffer else self.pasteBuffer.index(BRACKETED_PASTE_END));
            if (endIndex != -1) {
                pastedContent = self.pasteBuffer[0:endIndex];
                remaining = self.pasteBuffer[(endIndex + len(BRACKETED_PASTE_END)):];
                self.pasteMode = False;
                self.pasteBuffer = "";
                self.pendingKittyPrintableCodepoint = None;
                self.emit("paste", pastedContent);
                if (len(remaining) > 0) {
                    self.process(remaining);
                }
            }
            return;
        }
        result = extractCompleteSequences(self.buffer);
        self.buffer = (result["remainder"] as str);
        for sequence in (result["sequences"] as list[str]) {
            self.emitDataSequence(sequence);
        }
        if (len(self.buffer) > 0) {
            self.timeout = set_timeout(lambda () -> any { flushed = self.flush(); for sequence in flushed {     self.emitDataSequence(sequence); } }, self.timeoutMs);
        }
    }
    override def emitDataSequence(sequence: str) -> None {
        rawCodepoint = (ord(sequence[0]) if (len(sequence) == 1) else None);
        if ((rawCodepoint != None) and (rawCodepoint == self.pendingKittyPrintableCodepoint)) {
            self.pendingKittyPrintableCodepoint = None;
            return;
        }
        self.pendingKittyPrintableCodepoint = parseUnmodifiedKittyPrintableCodepoint(sequence);
        self.emit("data", sequence);
    }
    override def flush() -> list[str] {
        if self.timeout {
            clear_timeout(self.timeout);
            self.timeout = None;
        }
        if (len(self.buffer) == 0) {
            return [];
        }
        sequences = [self.buffer];
        self.buffer = "";
        self.pendingKittyPrintableCodepoint = None;
        return sequences;
    }
    override def clear() -> None {
        if self.timeout {
            clear_timeout(self.timeout);
            self.timeout = None;
        }
        self.buffer = "";
        self.pasteMode = False;
        self.pasteBuffer = "";
        self.pendingKittyPrintableCodepoint = None;
    }
    override def getBuffer() -> str {
        return self.buffer;
    }
    override def destroy() -> None {
        self.clear();
    }
}
