"""Jac-native runtime adapter for the ported pi-tui terminal boundary.

`terminal.ts` is the one module that genuinely talks to the OS terminal: Node's
`process.stdin`/`process.stdout` (raw mode, encoding, resize), `fs`, `path`,
`Date`, `setInterval`, and `process.platform`/`arch`/`pid`. None of that exists
under the Jac (CPython) runtime, so this module reproduces the JS-shaped surface
the converted `terminal.jac` calls, backed by the POSIX stdlib:

  - process.stdin  -> ProcessStdin  (termios/tty raw mode when a real TTY,
                       degrades to a flag + fed-bytes queue for headless smokes)
  - process.stdout -> ProcessStdout (sys.stdout write + os.get_terminal_size,
                       EventEmitter for "resize")
  - process.*      -> platform/arch/pid/execPath from sys/os, kill() via os.kill
  - fs / path      -> stat/isdir/append + posixpath join/dirname
  - Date / now_ms  -> time-based clock (getFullYear&c. from datetime)
  - set_interval / clear_interval -> registered, fired via run_pending_intervals

Like input_support, timers here are cooperative: there is no ambient event loop
in a headless `jac run`, so the progress keepalive interval is held and fired
explicitly. Under a real TTY the raw-mode and write paths are the genuine POSIX
calls, so this doubles as the actual terminal driver, not just a test double.
"""

import sys;
import os;
import time;
import datetime;
import from .input_support { EventEmitter, set_timeout, clear_timeout }

# ---------------------------------------------------------------------------
# Clock  (Date / Date.now equivalents)
# ---------------------------------------------------------------------------

def now_ms() -> float {
    return time.time() * 1000.0;
}

obj DateValue {
    has _dt: any = None;

    def __init__() -> None {
        self._dt = datetime.datetime.now();
    }
    def getFullYear() -> int { return self._dt.year; }
    def getMonth() -> int { return self._dt.month - 1; }   # JS months are 0-based
    def getDate() -> int { return self._dt.day; }
    def getHours() -> int { return self._dt.hour; }
    def getMinutes() -> int { return self._dt.minute; }
    def getSeconds() -> int { return self._dt.second; }
}

# ---------------------------------------------------------------------------
# Interval timers  (cooperative, mirroring input_support's TimerQueue)
# ---------------------------------------------------------------------------

obj IntervalQueue {
    has seq: int = 0;
    has pending: dict = {};

    def schedule(fn: any, ms: float) -> int {
        self.seq += 1;
        self.pending[self.seq] = fn;
        return self.seq;
    }
    def cancel(iid: any) -> None {
        self.pending.pop(iid, None);
    }
    def tick() -> int {
        fired = 0;
        for iid in sorted(list(self.pending.keys())) {
            fn = self.pending.get(iid, None);
            if fn { fn(); fired += 1; }
        }
        return fired;
    }
    def count() -> int { return len(self.pending); }
}

glob _intervalQueue = IntervalQueue();

def set_interval(fn: any, ms: float) -> int {
    return _intervalQueue.schedule(fn, ms);
}
def clear_interval(iid: any) -> None {
    _intervalQueue.cancel(iid);
}
def run_pending_intervals() -> int {
    return _intervalQueue.tick();
}

# ---------------------------------------------------------------------------
# fs / path  (only the members terminal.ts touches)
# ---------------------------------------------------------------------------

obj StatResult {
    has _isdir: bool = False;
    def isDirectory() -> bool { return self._isdir; }
}

obj FsAdapter {
    def statSync(p: str) -> StatResult {
        # Raises like fs.statSync when the path is missing; caller wraps in try.
        return StatResult(_isdir=os.path.isdir(p));
    }
    def appendFileSync(p: str, data: str, options: any = None) -> None {
        with open(p, "a", encoding="utf8") as fh {
            fh.write(data);
        }
    }
}

obj PathAdapter {
    def dirname(p: str) -> str { return os.path.dirname(p); }
    def join(*parts: any) -> str { return os.path.join(*parts); }
}

glob fs = FsAdapter();
glob path = PathAdapter();

# ---------------------------------------------------------------------------
# process.stdout
# ---------------------------------------------------------------------------

obj ProcessStdout {
    has emitter: EventEmitter = EventEmitter();
    has captured: list = [];
    has capture: bool = False;

    def __init__() -> None {
        self.emitter = EventEmitter();
        self.captured = [];
        self.capture = False;
    }

    def write(data: str) -> bool {
        if self.capture {
            self.captured.append(data);
        } else {
            try {
                sys.stdout.write(data);
                sys.stdout.flush();
            } except Exception { }
        }
        return True;
    }

    def _size() -> any {
        try {
            return os.get_terminal_size();
        } except Exception {
            return None;
        }
    }
    @property
    def columns() -> any {
        sz = self._size();
        return (sz.columns if sz is not None else None);
    }
    @property
    def rows() -> any {
        sz = self._size();
        return (sz.lines if sz is not None else None);
    }

    def on(event: str, fn: any) -> None { self.emitter.on(event, fn); }
    def removeListener(event: str, fn: any) -> None { self.emitter.off(event, fn); }
    def emit(event: str, arg: any = None) -> bool { return self.emitter.emit(event, arg); }
}

# ---------------------------------------------------------------------------
# process.stdin
# ---------------------------------------------------------------------------

obj ProcessStdin {
    has emitter: EventEmitter = EventEmitter();
    has isRaw: bool = False;
    has _resumed: bool = False;
    has _saved_attrs: any = None;
    has _fd: int = 0;

    def __init__() -> None {
        self.emitter = EventEmitter();
        try {
            self._fd = int(sys.stdin.fileno());
        } except Exception {
            self._fd = 0;
        }
    }

    def _isatty() -> bool {
        try {
            return bool(sys.stdin.isatty());
        } except Exception {
            return False;
        }
    }

    def setRawMode(enable: bool) -> ProcessStdin {
        if not self._isatty() {
            # Headless smoke: track the flag, skip the termios call.
            self.isRaw = enable;
            return self;
        }
        import termios;
        import tty;
        if enable {
            if self._saved_attrs is None {
                self._saved_attrs = termios.tcgetattr(self._fd);
            }
            tty.setraw(self._fd);
            self.isRaw = True;
        } else {
            if self._saved_attrs is not None {
                termios.tcsetattr(self._fd, termios.TCSADRAIN, self._saved_attrs);
                self._saved_attrs = None;
            }
            self.isRaw = False;
        }
        return self;
    }

    def setEncoding(enc: str) -> None { }        # CPython stdin is already text
    def resume() -> None { self._resumed = True; }
    def pause() -> None { self._resumed = False; }

    def on(event: str, fn: any) -> None { self.emitter.on(event, fn); }
    def removeListener(event: str, fn: any) -> None { self.emitter.off(event, fn); }

    def feed(data: str) -> bool {
        return self.emitter.emit("data", data);
    }
}

# ---------------------------------------------------------------------------
# process
# ---------------------------------------------------------------------------

obj ProcessAdapter {
    has stdin: ProcessStdin = ProcessStdin();
    has stdout: ProcessStdout = ProcessStdout();

    def __init__() -> None {
        self.stdin = ProcessStdin();
        self.stdout = ProcessStdout();
    }

    @property
    def platform() -> str {
        p = sys.platform;
        if p.startswith("linux") { return "linux"; }
        if p == "darwin" { return "darwin"; }
        if p.startswith("win") { return "win32"; }
        return p;
    }
    @property
    def arch() -> str {
        import platform as _pl;
        m = _pl.machine().lower();
        if m in ["x86_64", "amd64"] { return "x64"; }
        if m in ["aarch64", "arm64"] { return "arm64"; }
        return m;
    }
    @property
    def pid() -> int { return os.getpid(); }
    @property
    def execPath() -> str { return sys.executable; }

    def kill(pid: int, signal: any = None) -> None {
        # SIGWINCH self-poke is a no-op / best-effort under the adapter.
        try {
            import signal as _sig;
            if isinstance(signal, str) {
                sig = getattr(_sig, signal, None);
            } else {
                sig = signal;
            }
            if sig is not None {
                os.kill(pid, sig);
            }
        } except Exception { }
    }
}

glob process = ProcessAdapter();

# ---------------------------------------------------------------------------
# Misc JS globals used by the emitted terminal module
# ---------------------------------------------------------------------------

def Number(x: any) -> any {
    if x is None { return float("nan"); }
    try {
        s = str(x).strip();
        if s == "" { return float("nan"); }
        if ("." in s) or ("e" in s) or ("E" in s) { return float(s); }
        return int(s);
    } except Exception {
        return float("nan");
    }
}

def resolve_write_log_path() -> str {
    env = os.environ.get("PI_TUI_WRITE_LOG", "") or "";
    if not env { return ""; }
    try {
        if os.path.isdir(env) {
            now = DateValue();
            def p2(n: int) -> str { return str(n).rjust(2, "0"); }
            ts = f"{now.getFullYear()}-{p2(now.getMonth() + 1)}-{p2(now.getDate())}_{p2(now.getHours())}-{p2(now.getMinutes())}-{p2(now.getSeconds())}";
            return os.path.join(env, f"tui-{ts}-{process.pid}.log");
        }
    } except Exception { }
    return env;
}
