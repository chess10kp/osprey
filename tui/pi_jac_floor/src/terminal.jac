# interop import: node:fs { fs }
# interop import: node:module { createRequire }
# interop import: node:path { path }
# interop import: node:url { fileURLToPath }
import from "./keys.jac" { setKittyProtocolActive }
import from "./native-modifiers.jac" { isNativeModifierPressed }
import from "./stdin-buffer.jac" { StdinBuffer }
import from re { search }
import from os { environ }

glob cjsRequire = createRequire(__file__);

glob TERMINAL_PROGRESS_KEEPALIVE_MS = 1000;

glob TERMINAL_PROGRESS_ACTIVE_SEQUENCE = "\u001b]9;4;3\u0007";

glob TERMINAL_PROGRESS_CLEAR_SEQUENCE = "\u001b]9;4;0;\u0007";

glob APPLE_TERMINAL_SHIFT_ENTER_SEQUENCE = "\u001b[13;2u";

glob DESIRED_KITTY_KEYBOARD_PROTOCOL_FLAGS = 7;

glob KEYBOARD_PROTOCOL_RESPONSE_FRAGMENT_TIMEOUT_MS = 150;

glob KITTY_KEYBOARD_PROTOCOL_QUERY = f"\\x1b[>{DESIRED_KITTY_KEYBOARD_PROTOCOL_FLAGS}u\\x1b[?u\\x1b[c";

def:pub parseKeyboardProtocolNegotiationSequence(sequence: str) -> any | None {
    kittyFlags = search(r"^\x1b\[\?(\d+)u$", sequence);
    if kittyFlags {
        return {"type": "kitty-flags", "flags": int((kittyFlags.group(1) as any), 10)};
    }
    if (search(r"^\x1b\[\?[\d;]*c$", sequence) is not None) {
        return {"type": "device-attributes"};
    }
    return None;
}

def isKeyboardProtocolNegotiationSequencePrefix(sequence: str) -> bool {
    return ((sequence == "\u001b[") or (search(r"^\x1b\[\?[\d;]*$", sequence) is not None));
}

def:pub isAppleTerminalSession() -> bool {
    return ((process.platform == "darwin") and (environ.get("TERM_PROGRAM") == "Apple_Terminal"));
}

def:pub normalizeAppleTerminalInput(data: str, isAppleTerminal: bool, isShiftPressed: bool) -> str {
    if ((isAppleTerminal and (data == "\r")) and isShiftPressed) {
        return APPLE_TERMINAL_SHIFT_ENTER_SEQUENCE;
    }
    return data;
}

obj:pub ProcessTerminal {
    has inputHandler: any | None = None;
    has resizeHandler: any | None = None;
    has keyboardProtocolBufferFlushTimer: any | None = None;
    has stdinBuffer: any | None = None;
    has stdinDataHandler: any | None = None;
    has progressInterval: any | None = None;
    has wasRaw: bool = False;
    has _kittyProtocolActive: bool = False;
    has _modifyOtherKeysActive: bool = False;
    has keyboardProtocolPushed: bool = False;
    has keyboardProtocolNegotiationBuffer: str = "";
    has writeLogPath: any = (lambda () -> any { env = (environ.get("PI_TUI_WRITE_LOG") or ""); if not env {     return ""; } try {     if fs.statSync(env).isDirectory() {         now = Date();         ts: str = f"{now.getFullYear()}-{str((now.getMonth() + 1)).padStart(2, "0")}-{str(now.getDate()).padStart(2, "0")}_{str(now.getHours()).padStart(2, "0")}-{str(now.getMinutes()).padStart(2, "0")}-{str(now.getSeconds()).padStart(2, "0")}";         return env.join(path);     } } except Exception { } return env; })();
    # JS2JAC-HOLE[E7205] Class getters/setters are not supported:
    # | get kittyProtocolActive(): boolean {
    # | 		return this._kittyProtocolActive;
    # | 	}
    # JS2JAC-HOLE[E7205] Class getters/setters are not supported:
    # | get modifyOtherKeysActive(): boolean {
    # | 		return this._modifyOtherKeysActive;
    # | 	}
    def start(onInput: any, onResize: any) -> None {
        self.inputHandler = onInput;
        self.resizeHandler = onResize;
        self.wasRaw = (process.stdin.isRaw or False);
        if process.stdin.setRawMode {
            process.stdin.setRawMode(True);
        }
        process.stdin.setEncoding("utf8");
        process.stdin.resume();
        process.stdout.write("\u001b[?2004h");
        process.stdout.on("resize", self.resizeHandler);
        if (process.platform != "win32") {
            process.kill(process.pid, "SIGWINCH");
        }
        self.enableWindowsVTInput();
        self.queryAndEnableKittyProtocol();
    }
    def setupStdinBuffer() -> None {
        self.stdinBuffer = StdinBuffer({"timeout": 10});
        self.stdinBuffer.on("data", lambda (sequence: any) -> any { negotiationSequence = self.readKeyboardProtocolNegotiationSequence(sequence); if (negotiationSequence == "pending") {     self.scheduleKeyboardProtocolNegotiationBufferFlush();     return; } if self.handleKeyboardProtocolNegotiationSequence(negotiationSequence) {     return; } self.forwardInputSequence(sequence); });
        self.stdinBuffer.on("paste", lambda (content: any) -> any { if self.inputHandler {     self.inputHandler(f"\\x1b[200~{content}\\x1b[201~"); } });
        self.stdinDataHandler = lambda (data: str) -> any { (self.stdinBuffer as any).process(data); };
    }
    def queryAndEnableKittyProtocol() -> None {
        self.setupStdinBuffer();
        process.stdin.on("data", (self.stdinDataHandler as any));
        self.keyboardProtocolPushed = True;
        self.clearKeyboardProtocolNegotiationBuffer();
        process.stdout.write(KITTY_KEYBOARD_PROTOCOL_QUERY);
    }
    def handleKeyboardProtocolNegotiationSequence(negotiationSequence: any | None) -> bool {
        if not negotiationSequence {
            return False;
        }
        self.clearKeyboardProtocolNegotiationBuffer();
        if (negotiationSequence.type == "kitty-flags") {
            if (negotiationSequence.flags != 0) {
                self.disableModifyOtherKeys();
                if not self._kittyProtocolActive {
                    self._kittyProtocolActive = True;
                    setKittyProtocolActive(True);
                }
            }
            else {
                self.enableModifyOtherKeys();
            }
            return True;
        }
        if not self._kittyProtocolActive {
            self.enableModifyOtherKeys();
        }
        return True;
    }
    def readKeyboardProtocolNegotiationSequence(sequence: str) -> any | None {
        if self.keyboardProtocolNegotiationBuffer {
            bufferedSequence = (self.keyboardProtocolNegotiationBuffer + sequence);
            negotiationSequence = parseKeyboardProtocolNegotiationSequence(bufferedSequence);
            if negotiationSequence {
                self.clearKeyboardProtocolNegotiationBuffer();
                return negotiationSequence;
            }
            if isKeyboardProtocolNegotiationSequencePrefix(bufferedSequence) {
                self.setKeyboardProtocolNegotiationBuffer(bufferedSequence);
                return "pending";
            }
            self.flushKeyboardProtocolNegotiationBufferAsInput();
        }
        negotiationSequence = parseKeyboardProtocolNegotiationSequence(sequence);
        if negotiationSequence {
            return negotiationSequence;
        }
        if isKeyboardProtocolNegotiationSequencePrefix(sequence) {
            self.setKeyboardProtocolNegotiationBuffer(sequence);
            return "pending";
        }
        return None;
    }
    def setKeyboardProtocolNegotiationBuffer(sequence: str) -> None {
        self.clearKeyboardProtocolNegotiationBufferFlushTimer();
        self.keyboardProtocolNegotiationBuffer = sequence;
    }
    def clearKeyboardProtocolNegotiationBuffer() -> None {
        self.clearKeyboardProtocolNegotiationBufferFlushTimer();
        self.keyboardProtocolNegotiationBuffer = "";
    }
    def flushKeyboardProtocolNegotiationBufferAsInput() -> None {
        if not self.keyboardProtocolNegotiationBuffer {
            return;
        }
        sequence = self.keyboardProtocolNegotiationBuffer;
        self.clearKeyboardProtocolNegotiationBuffer();
        self.forwardInputSequence(sequence);
    }
    def scheduleKeyboardProtocolNegotiationBufferFlush() -> None {
        if (not self.keyboardProtocolNegotiationBuffer or self.keyboardProtocolBufferFlushTimer) {
            return;
        }
        self.keyboardProtocolBufferFlushTimer = setTimeout(lambda () -> any { self.keyboardProtocolBufferFlushTimer = None; self.flushKeyboardProtocolNegotiationBufferAsInput(); }, KEYBOARD_PROTOCOL_RESPONSE_FRAGMENT_TIMEOUT_MS);
    }
    def clearKeyboardProtocolNegotiationBufferFlushTimer() -> None {
        if not self.keyboardProtocolBufferFlushTimer {
            return;
        }
        clearTimeout(self.keyboardProtocolBufferFlushTimer);
        self.keyboardProtocolBufferFlushTimer = None;
    }
    def forwardInputSequence(sequence: str) -> None {
        if not self.inputHandler {
            return;
        }
        isAppleTerminal = ((sequence == "\r") and isAppleTerminalSession());
        input = normalizeAppleTerminalInput(sequence, isAppleTerminal, (isAppleTerminal and isNativeModifierPressed("shift")));
        self.inputHandler(input);
    }
    def enableModifyOtherKeys() -> None {
        if (self._kittyProtocolActive or self._modifyOtherKeysActive) {
            return;
        }
        process.stdout.write("\u001b[>4;2m");
        self._modifyOtherKeysActive = True;
    }
    def disableModifyOtherKeys() -> None {
        if not self._modifyOtherKeysActive {
            return;
        }
        process.stdout.write("\u001b[>4;0m");
        self._modifyOtherKeysActive = False;
    }
    def enableWindowsVTInput() -> None {
        if (process.platform != "win32") {
            return;
        }
        try {
            arch = process.arch;
            if ((arch != "x64") and (arch != "arm64")) {
                return;
            }
            moduleDir = path.dirname(fileURLToPath(__file__));
            nativePath = "native".join(path);
            candidates = [moduleDir.join(path), moduleDir.join(path), path.dirname(process.execPath).join(path)];
            for modulePath in candidates {
                try {
                    helper = cjsRequire(modulePath);
                    (helper.enableVirtualTerminalInput() if helper.enableVirtualTerminalInput is not None else None);
                    return;
                }
                except Exception {
                }
            }
        }
        except Exception {
        }
    }
    # JS2JAC-HOLE[E7205] Async class methods are not supported:
    # | async drainInput(maxMs = 1000, idleMs = 50): Promise<void> {
    # | 		const shouldDisableKittyProtocol = this.keyboardProtocolPushed || this._kittyProtocolActive;
    # | 		this.clearKeyboardProtocolNegotiationBuffer();
    # | 		if (shouldDisableKittyProtocol) {
    # | 			// Disable Kitty keyboard protocol first so any late key releases
    # | 			// do not generate new Kitty escape sequences.
    # | 			process.stdout.write("\x1b[<u");
    # | 			this.keyboardProtocolPushed = false;
    # | 			this._kittyProtocolActive = false;
    # | 			setKittyProtocolActive(false);
    # | 		}
    # | 		this.disableModifyOtherKeys();
    # | 
    # | 		const previousHandler = this.inputHandler;
    # | 		this.inputHandler = undefined;
    # | 
    # | 		let lastDataTime = Date.now();
    # | 		const onData = () => {
    # | 			lastDataTime = Date.now();
    # | 		};
    # | 
    # | 		process.stdin.on("data", onData);
    # | 		const endTime = Date.now() + maxMs;
    # | 
    # | 		try {
    # | 			while (true) {
    # | 				const now = Date.now();
    # | 				const timeLeft = endTime - now;
    # | 				if (timeLeft <= 0) break;
    # | 				if (now - lastDataTime >= idleMs) break;
    # | 				await new Promise((resolve) => setTimeout(resolve, Math.min(idleMs, timeLeft)));
    # | 			}
    # | 		} finally {
    # | 			process.stdin.removeListener("data", onData);
    # | 			this.inputHandler = previousHandler;
    # | 		}
    # | 	}
    def stop() -> None {
        if self.clearProgressInterval() {
            process.stdout.write(TERMINAL_PROGRESS_CLEAR_SEQUENCE);
        }
        process.stdout.write("\u001b[?2004l");
        shouldDisableKittyProtocol = (self.keyboardProtocolPushed or self._kittyProtocolActive);
        self.clearKeyboardProtocolNegotiationBuffer();
        if shouldDisableKittyProtocol {
            process.stdout.write("\u001b[<u");
            self.keyboardProtocolPushed = False;
            self._kittyProtocolActive = False;
            setKittyProtocolActive(False);
        }
        self.disableModifyOtherKeys();
        if self.stdinBuffer {
            self.stdinBuffer.destroy();
            self.stdinBuffer = None;
        }
        if self.stdinDataHandler {
            process.stdin.removeListener("data", self.stdinDataHandler);
            self.stdinDataHandler = None;
        }
        self.inputHandler = None;
        if self.resizeHandler {
            process.stdout.removeListener("resize", self.resizeHandler);
            self.resizeHandler = None;
        }
        process.stdin.pause();
        if process.stdin.setRawMode {
            process.stdin.setRawMode(self.wasRaw);
        }
    }
    def write(data: str) -> None {
        process.stdout.write(data);
        if self.writeLogPath {
            try {
                fs.appendFileSync(self.writeLogPath, data, {"encoding": "utf8"});
            }
            except Exception {
            }
        }
    }
    # JS2JAC-HOLE[E7205] Class getters/setters are not supported:
    # | get columns(): number {
    # | 		return process.stdout.columns || Number(process.env.COLUMNS) || 80;
    # | 	}
    # JS2JAC-HOLE[E7205] Class getters/setters are not supported:
    # | get rows(): number {
    # | 		return process.stdout.rows || Number(process.env.LINES) || 24;
    # | 	}
    def moveBy(lines: float) -> None {
        if (lines > 0) {
            process.stdout.write(f"\\x1b[{lines}B");
        }
        elif (lines < 0) {
            process.stdout.write(f"\\x1b[{-lines}A");
        }
    }
    def hideCursor() -> None {
        process.stdout.write("\u001b[?25l");
    }
    def showCursor() -> None {
        process.stdout.write("\u001b[?25h");
    }
    def clearLine() -> None {
        process.stdout.write("\u001b[K");
    }
    def clearFromCursor() -> None {
        process.stdout.write("\u001b[J");
    }
    def clearScreen() -> None {
        process.stdout.write("\u001b[2J\u001b[H");
    }
    def setTitle(title: str) -> None {
        process.stdout.write(f"\\x1b]0;{title}\\x07");
    }
    def setProgress(active: bool) -> None {
        if active {
            process.stdout.write(TERMINAL_PROGRESS_ACTIVE_SEQUENCE);
            if not self.progressInterval {
                self.progressInterval = setInterval(lambda () -> any { process.stdout.write(TERMINAL_PROGRESS_ACTIVE_SEQUENCE); }, TERMINAL_PROGRESS_KEEPALIVE_MS);
            }
        }
        else {
            self.clearProgressInterval();
            process.stdout.write(TERMINAL_PROGRESS_CLEAR_SEQUENCE);
        }
    }
    def clearProgressInterval() -> bool {
        if not self.progressInterval {
            return False;
        }
        clearInterval(self.progressInterval);
        self.progressInterval = None;
        return True;
    }
}
