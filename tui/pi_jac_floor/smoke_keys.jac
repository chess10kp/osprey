"""Runtime smoke for the sequence -> key-name mapper (keys.jac).

Proves the converted key parser executes under the Jac runtime: raw escape
sequences and control bytes are mapped to semantic key names (up, ctrl+a,
alt+x, delete, ...). Chains onto stdin_buffer: StdinBuffer segments bytes into
sequences, parseKey names each one -> bytes to semantic key events end to end.

Run: jac run smoke_keys.jac
"""

import from src.keys { parseKey, decodePrintableKey, matchesKey }
import from src.stdin_buffer { StdinBuffer }

glob ESC = chr(27);

def names(input: str) -> list[str] {
    # Full pipeline: segment raw bytes, then name each sequence.
    sb = StdinBuffer();
    seen: list[str] = [];
    sb.on("data", lambda (s: any) -> any { seen.append(parseKey(s)); });
    sb.process(input);
    return seen;
}

with entry {
    # --- parseKey: direct sequence -> name ---
    assert parseKey("a") == "a";
    assert parseKey(chr(1)) == "ctrl+a";          # C-a
    assert parseKey("\t") == "tab";
    assert parseKey("\r") == "enter";
    assert parseKey(" ") == "space";
    assert parseKey(chr(127)) == "backspace";
    assert parseKey(ESC) == "escape";

    # CSI arrows
    assert parseKey(f"{ESC}[A") == "up";
    assert parseKey(f"{ESC}[B") == "down";
    assert parseKey(f"{ESC}[C") == "right";
    assert parseKey(f"{ESC}[D") == "left";

    # Functional keys (legacy CSI ~)
    assert parseKey(f"{ESC}[3~") == "delete";
    assert parseKey(f"{ESC}[5~") == "pageUp";
    assert parseKey(f"{ESC}[6~") == "pageDown";
    assert parseKey(f"{ESC}[H") == "home";
    assert parseKey(f"{ESC}[F") == "end";

    # Alt-prefixed printable: ESC + letter
    assert parseKey(f"{ESC}x") == "alt+x";
    assert parseKey(f"{ESC}[Z") == "shift+tab";

    # Unrecognized -> None
    assert parseKey(f"{ESC}[999999Z") == None;

    # --- decodePrintableKey: non-printable control -> None ---
    assert decodePrintableKey("a") == None;   # plain ascii is not a kitty/MOK printable seq

    # --- matchesKey: sequence matches a key id ---
    assert matchesKey(f"{ESC}[A", "up") == True;
    assert matchesKey(f"{ESC}[A", "down") == False;
    assert matchesKey(chr(1), "ctrl+a") == True;

    # --- full pipeline: bytes -> segments -> names ---
    piped = names(f"ab{ESC}[Cz");
    assert piped == ["a", "b", "right", "z"];

    print("smoke_keys OK (parseKey / decodePrintableKey / matchesKey / pipeline)");
}
