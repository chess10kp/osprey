"""Runtime smoke for the input parsing core (StdinBuffer).

Proves the converted stdin pipeline executes under the Jac runtime via the
input_support adapters (EventEmitter + cooperative timers): raw terminal bytes
are segmented into discrete escape sequences, bracketed paste is lifted into a
`paste` event, and an incomplete tail is held then flushed on timer.

No Node/terminal deps — StdinBuffer.process() is driven directly.

Run: jac run smoke_input.jac
"""

import from src.stdin_buffer { StdinBuffer, extractCompleteSequences }
import from src.input_support { run_pending_timers, pending_timer_count }

glob ESC = "";

def collect(input: str) -> list[str] {
    sb = StdinBuffer();
    seen: list[str] = [];
    sb.on("data", lambda (s: any) -> any { seen.append(s); });
    sb.process(input);
    return seen;
}

with entry {
    # 1. Plain ASCII splits into one sequence per character.
    ascii_seq = collect("abc");
    assert ascii_seq == ["a", "b", "c"];

    # 2. A cursor-up arrow (CSI A) stays one atomic sequence.
    up = collect(f"{ESC}[A");
    assert up == [f"{ESC}[A"];

    # 3. An SGR mouse report (CSI < ... M) is recognized as complete.
    mouse = collect(f"{ESC}[<0;10;20M");
    assert mouse == [f"{ESC}[<0;10;20M"];

    # 4. Mixed: printable, then arrow, then printable.
    mixed = collect(f"x{ESC}[Cy");
    assert mixed == ["x", f"{ESC}[C", "y"];

    # 5. Bracketed paste is lifted out of the data stream into a paste event.
    sb = StdinBuffer();
    data_events: list[str] = [];
    paste_events: list[str] = [];
    sb.on("data", lambda (s: any) -> any { data_events.append(s); });
    sb.on("paste", lambda (s: any) -> any { paste_events.append(s); });
    sb.process(f"{ESC}[200~hello world{ESC}[201~");
    assert paste_events == ["hello world"];
    assert data_events == [];

    # 6. An incomplete CSI tail is buffered (not emitted), a flush timer armed,
    #    then delivered verbatim when the timer fires.
    sb2 = StdinBuffer();
    tail_events: list[str] = [];
    sb2.on("data", lambda (s: any) -> any { tail_events.append(s); });
    sb2.process(f"{ESC}[");
    assert tail_events == [];              # held: could still become a full sequence
    assert pending_timer_count() >= 1;     # flush scheduled
    fired = run_pending_timers();
    assert fired >= 1;
    assert tail_events == [f"{ESC}["];     # flushed verbatim on timeout

    # extractCompleteSequences leaves a genuine partial as remainder.
    part = extractCompleteSequences(f"a{ESC}[");
    assert part["sequences"] == ["a"];
    assert part["remainder"] == f"{ESC}[";

    print("smoke_input OK (ascii/arrow/mouse/paste/flush)");
}
