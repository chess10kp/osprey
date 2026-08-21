"""Product-owned terminal seam: process adapter + shared interface contract.

ProcessTerminal ports the required host behavior from the floor reference
(raw mode, alternate screen, bracketed paste enable, synchronized output,
SIGWINCH resize, and reliable restoration) using Python stdlib only
(`termios`, `tty`, `select`, `signal`, `fcntl`). It does not import or
modify `tui/pi_jac_floor`.

VirtualTerminal (virtual_terminal.jac) is the primary test adapter.
"""

import sys;
import os;
import atexit;
import signal;
import select;
import termios;
import tty;
import fcntl;
import struct;


glob ESC = "\x1b";
glob ENABLE_BRACKETED_PASTE = "\x1b[?2004h";
glob DISABLE_BRACKETED_PASTE = "\x1b[?2004l";
glob ENTER_ALT_SCREEN = "\x1b[?1049h";
glob LEAVE_ALT_SCREEN = "\x1b[?1049l";
glob SYNC_BEGIN = "\x1b[?2026h";
glob SYNC_END = "\x1b[?2026l";
glob HIDE_CURSOR = "\x1b[?25l";
glob SHOW_CURSOR = "\x1b[?25h";
glob CLEAR_SCREEN = "\x1b[2J\x1b[H";


"""Minimal terminal capability surface used by the renderer and host loop."""
obj Terminal {
    has columns: int = 80,
        rows: int = 24,
        started: bool = False,
        restored: bool = True,
        alternate_screen: bool = False,
        bracketed_paste: bool = False,
        cursor_visible: bool = True,
        sync_active: bool = False;

    def size() -> tuple[int, int] {
        return (self.columns, self.rows);
    }

    def write(data: str) -> None {
        raise NotImplementedError("Terminal.write");
    }

    def start() -> None {
        raise NotImplementedError("Terminal.start");
    }

    def stop() -> None {
        raise NotImplementedError("Terminal.stop");
    }

    def enter_alternate_screen() -> None {
        self.write(ENTER_ALT_SCREEN);
        self.alternate_screen = True;
    }

    def leave_alternate_screen() -> None {
        self.write(LEAVE_ALT_SCREEN);
        self.alternate_screen = False;
    }

    def begin_synchronized_update() -> None {
        self.write(SYNC_BEGIN);
        self.sync_active = True;
    }

    def end_synchronized_update() -> None {
        self.write(SYNC_END);
        self.sync_active = False;
    }

    def hide_cursor() -> None {
        self.write(HIDE_CURSOR);
        self.cursor_visible = False;
    }

    def show_cursor() -> None {
        self.write(SHOW_CURSOR);
        self.cursor_visible = True;
    }

    def clear_screen() -> None {
        self.write(CLEAR_SCREEN);
    }

    def enable_bracketed_paste() -> None {
        self.write(ENABLE_BRACKETED_PASTE);
        self.bracketed_paste = True;
    }

    def disable_bracketed_paste() -> None {
        self.write(DISABLE_BRACKETED_PASTE);
        self.bracketed_paste = False;
    }

    def set_title(title: str) -> None {
        self.write(f"\x1b]0;{title}\x07");
    }

    def move_cursor(row: int, col: int) -> None {
        self.write(f"\x1b[{row};{col}H");
    }

    """Restore host terminal modes. Safe to call more than once."""
    def restore() -> None {
        self.stop();
    }
}


def _ioctl_winsize(fd: int) -> tuple[int, int] | None {
    try {
        packed = fcntl.ioctl(fd, termios.TIOCGWINSZ, struct.pack("HHHH", 0, 0, 0, 0));
        (rows, cols, _x, _y) = struct.unpack("HHHH", packed);
        if rows > 0 and cols > 0 {
            return (cols, rows);
        }
    } except Exception {
    }
    return None;
}


def read_terminal_size(fallback_cols: int = 80, fallback_rows: int = 24) -> tuple[int, int] {
    for stream in [sys.stdout, sys.stdin, sys.stderr] {
        try {
            fd = stream.fileno() as int;
        } except Exception {
            continue;
        }
        got = _ioctl_winsize(fd);
        if got is not None {
            return got;
        }
    }
    env_cols = os.environ.get("COLUMNS");
    env_rows = os.environ.get("LINES");
    cols = int(env_cols) if env_cols else fallback_cols;
    rows = int(env_rows) if env_rows else fallback_rows;
    if cols <= 0 {
        cols = fallback_cols;
    }
    if rows <= 0 {
        rows = fallback_rows;
    }
    return (cols, rows);
}


"""POSIX process terminal using termios raw mode and signal-driven resize."""
obj ProcessTerminal(Terminal) {
    has _fd: int = -1,
        _old_attrs: any = None,
        _old_handler: any = None,
        _old_sigint: any = None,
        _atexit_registered: bool = False,
        _stdin_buf: str = "",
        on_resize: any = None,
        on_input: any = None,
        on_interrupt: any = None;

    def init(
        on_input: any = None,
        on_resize: any = None,
        on_interrupt: any = None,
    ) {
        super.init();
        self.on_input = on_input;
        self.on_resize = on_resize;
        self.on_interrupt = on_interrupt;
        self._fd = -1;
        self._old_attrs = None;
        self._old_handler = None;
        self._old_sigint = None;
        self._atexit_registered = False;
        self._stdin_buf = "";
        self.restored = True;
    }

    def write(data: str) -> None {
        if not data {
            return;
        }
        sys.stdout.write(data);
        sys.stdout.flush();
    }

    def _refresh_size() {
        (cols, rows) = read_terminal_size(self.columns, self.rows);
        changed = cols != self.columns or rows != self.rows;
        self.columns = cols;
        self.rows = rows;
        if changed and self.on_resize is not None {
            self.on_resize(cols, rows);
        }
    }

    def _on_sigwinch(signum: int, frame: any) {
        self._refresh_size();
    }

    def _on_sigint(signum: int, frame: any) {
        self.restore();
        if self.on_interrupt is not None {
            self.on_interrupt();
        } else {
            raise KeyboardInterrupt();
        }
    }

    def start() -> None {
        if self.started {
            return;
        }
        if not sys.stdin.isatty() {
            raise RuntimeError("ProcessTerminal requires a TTY stdin");
        }
        self._fd = sys.stdin.fileno() as int;
        self._old_attrs = termios.tcgetattr(self._fd);
        tty.setraw(self._fd);
        self._refresh_size();
        sigwinch = signal.SIGWINCH as int;
        sigint = signal.SIGINT as int;
        self._old_handler = signal.signal(sigwinch, self._on_sigwinch);
        self._old_sigint = signal.signal(sigint, self._on_sigint);
        if not self._atexit_registered {
            atexit.register(self.restore);
            self._atexit_registered = True;
        }
        self.enable_bracketed_paste();
        self.enter_alternate_screen();
        self.hide_cursor();
        self.started = True;
        self.restored = False;
    }

    def stop() -> None {
        if self.restored and not self.started {
            return;
        }
        try {
            if self.sync_active {
                self.end_synchronized_update();
            }
            if self.bracketed_paste {
                self.disable_bracketed_paste();
            }
            if self.alternate_screen {
                self.leave_alternate_screen();
            }
            if not self.cursor_visible {
                self.show_cursor();
            }
        } except Exception {
        }
        if self._old_handler is not None {
            try {
                signal.signal(signal.SIGWINCH as int, self._old_handler);
            } except Exception {
            }
            self._old_handler = None;
        }
        if self._old_sigint is not None {
            try {
                signal.signal(signal.SIGINT as int, self._old_sigint);
            } except Exception {
            }
            self._old_sigint = None;
        }
        if self._old_attrs is not None and self._fd >= 0 {
            try {
                termios.tcsetattr(self._fd, termios.TCSADRAIN, self._old_attrs);
            } except Exception {
            }
            self._old_attrs = None;
        }
        self.started = False;
        self.restored = True;
    }

    """Non-blocking poll of stdin. Returns raw byte string (may be empty)."""
    def poll_input(timeout_s: float = 0.0) -> str {
        if not self.started or self._fd < 0 {
            return "";
        }
        ready = select.select([self._fd], [], [], timeout_s);
        if not ready[0] {
            return "";
        }
        try {
            data = os.read(self._fd, 8192);
        } except BlockingIOError {
            return "";
        } except OSError {
            return "";
        }
        if not data {
            return "";
        }
        text = data.decode("utf-8", errors="replace");
        if self.on_input is not None {
            self.on_input(text);
        }
        return text;
    }
}


"""Emit one synchronized write: begin sync, body, end sync."""
def synchronized_write(term: Terminal, data: str) {
    term.begin_synchronized_update();
    try {
        term.write(data);
    } finally {
        term.end_synchronized_update();
    }
}
