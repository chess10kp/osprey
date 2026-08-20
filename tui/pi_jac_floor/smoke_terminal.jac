"""Runtime smoke for the terminal boundary (terminal.jac + terminal_support.jac).

terminal.ts is the one module that genuinely drives the OS terminal: Node
process.stdin/stdout raw mode, resize, fs/path, Date, setInterval. The
Jac-native terminal_support adapter reproduces that surface on the POSIX
stdlib, degrading to a headless (non-TTY) mode here so the whole lifecycle
runs under `jac run` with stdout captured instead of emitted.

Proves end to end: kitty-protocol negotiation parsing, the stdin -> data ->
input-handler forwarding path, the progress keepalive interval, cursor moves,
and the columns/rows fallback -- all executing, not just type-checking.

Run: jac run smoke_terminal.jac
"""

import from src.terminal {
    ProcessTerminal,
    parseKeyboardProtocolNegotiationSequence,
    isKeyboardProtocolNegotiationSequencePrefix,
    normalizeAppleTerminalInput,
    APPLE_TERMINAL_SHIFT_ENTER_SEQUENCE
}
import from src.terminal_support { process, run_pending_intervals }

glob ESC = chr(27);

def has_seq(needle: str) -> bool {
    for chunk in process.stdout.captured {
        if needle in chunk { return True; }
    }
    return False;
}

with entry {
    # --- Pure: keyboard-protocol negotiation parsing ---
    kitty = parseKeyboardProtocolNegotiationSequence(f"{ESC}[?7u");
    assert kitty["type"] == "kitty-flags";
    assert kitty["flags"] == 7;
    assert parseKeyboardProtocolNegotiationSequence(f"{ESC}[?1;2c") == {"type": "device-attributes"};
    assert parseKeyboardProtocolNegotiationSequence("x") == None;

    assert isKeyboardProtocolNegotiationSequencePrefix(f"{ESC}[") == True;
    assert isKeyboardProtocolNegotiationSequencePrefix(f"{ESC}[?12") == True;
    assert isKeyboardProtocolNegotiationSequencePrefix("abc") == False;

    # --- Pure: Apple Terminal shift+enter normalization ---
    assert normalizeAppleTerminalInput("\r", True, True) == APPLE_TERMINAL_SHIFT_ENTER_SEQUENCE;
    assert normalizeAppleTerminalInput("\r", False, True) == "\r";
    assert normalizeAppleTerminalInput("a", True, True) == "a";

    # Capture stdout instead of writing to the real terminal.
    process.stdout.capture = True;
    process.stdout.captured = [];

    # --- Lifecycle: start -> negotiate kitty -> forward input -> stop ---
    inputs: list = [];
    resizes: list = [];
    term = ProcessTerminal();
    term.start(
        lambda (s: any) -> any { inputs.append(s); },
        lambda (a: any = None) -> any { resizes.append(True); }
    );
    # start() writes the bracketed-paste enable and the kitty query.
    assert has_seq("[?2004h");
    assert has_seq(f"{ESC}[>7u");        # DESIRED_KITTY_KEYBOARD_PROTOCOL_FLAGS query
    assert term.kittyProtocolActive() == False;

    # Terminal answers the query: kitty flags active. Feed it as stdin bytes.
    process.stdin.feed(f"{ESC}[?7u");
    assert term.kittyProtocolActive() == True;
    assert inputs == [];                 # negotiation reply is consumed, not forwarded

    # A real keypress flows through to the input handler.
    process.stdin.feed("a");
    assert inputs == ["a"];

    # resize event fans out to the handler.
    process.stdout.emit("resize");
    assert resizes == [True];

    # --- Progress keepalive interval ---
    process.stdout.captured = [];
    term.setProgress(True);
    assert has_seq("]9;4;3");     # ACTIVE sequence
    process.stdout.captured = [];
    fired = run_pending_intervals();          # cooperative event loop
    assert fired == 1;
    assert has_seq("]9;4;3");     # keepalive re-emits ACTIVE
    term.setProgress(False);
    assert has_seq("]9;4;0;");     # CLEAR sequence
    assert run_pending_intervals() == 0;       # interval cleared

    # --- Cursor moves emit real ESC sequences (not literal "\x1b") ---
    process.stdout.captured = [];
    term.moveBy(3);
    term.moveBy(-2);
    assert has_seq(f"{ESC}[3B");
    assert has_seq(f"{ESC}[2A");
    assert ord(process.stdout.captured[0][0]) == 27;   # genuine ESC byte

    # --- Dimensions fall back sanely with no TTY ---
    assert term.columns() >= 1;
    assert term.rows() >= 1;

    term.stop();
    assert has_seq("[?2004l");           # stop disables bracketed paste
    assert term.kittyProtocolActive() == False;

    process.stdout.capture = False;
    print("smoke_terminal OK (negotiation / input forward / progress / moveBy / lifecycle)");
}
