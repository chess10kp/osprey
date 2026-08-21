"""Helpers for interactive pi-tui-floor demos (real TTY + headless fallback).

The converted terminal adapter registers stdin listeners but does not spawn a
background reader. Smokes call process.stdin.feed() directly; live demos must
pump os.read() chunks into that same path and drain cooperative timers.

The event loop uses select() with a short timeout so render debounce timers
fire even between keystrokes (otherwise the UI only updates on the next key).
"""

import os;
import sys;
import select;
import from src.terminal_support { process, run_pending_intervals }
import from src.input_support { run_pending_timers, pending_timer_count }

glob ESC = chr(27);

def drain_cooperative(max_rounds: int = 32) -> None {
    rounds: int = 0;
    while (rounds < max_rounds) and (pending_timer_count() > 0) {
        run_pending_timers();
        rounds += 1;
    }
    run_pending_intervals();
}

def stdin_is_tty() -> bool {
    try {
        return bool(sys.stdin.isatty());
    } except Exception {
        return False;
    }
}

def enter_fullscreen(term: any) -> None {
    # Alternate screen + clear: isolate from shell scrollback like a real TUI.
    term.write(f"{ESC}[?1049h{ESC}[2J{ESC}[H{ESC}[3J");
}

def leave_fullscreen(term: any) -> None {
    term.write(f"{ESC}[?1049l");
}

def clear_screen(term: any) -> None {
    term.clearScreen();
}

def feed_stdin(data: str) -> None {
    if data {
        process.stdin.feed(data);
        drain_cooperative();
    }
}

def run_interactive(should_continue: any, on_tick: any) -> None {
    fd = process.stdin._fd;
    poll_ms = 0.016;
    while should_continue() {
        drain_cooperative();
        if on_tick is not None {
            on_tick();
        }
        try {
            poll = select.select([sys.stdin], [], [], poll_ms);
            ready = poll[0];
        } except Exception {
            ready = [];
        }
        if not ready {
            continue;
        }
        try {
            raw = os.read(fd, 4096);
        } except KeyboardInterrupt {
            break;
        } except Exception {
            break;
        }
        if not raw {
            break;
        }
        chunk = raw.decode("utf8", errors="replace");
        if ("\x03" in chunk) or ("\x04" in chunk) {
            break;
        }
        feed_stdin(chunk);
    }
}

def run_scripted(chunks: list[str], should_continue: any) -> None {
    for chunk in chunks {
        if not should_continue() {
            break;
        }
        feed_stdin(chunk);
    }
}
