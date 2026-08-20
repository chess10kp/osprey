"""Jac-native runtime adapters for the ported pi-tui input path.

The js2jac conversion of the stdin/keyboard pipeline left Node-runtime globals
in place: the `events` `EventEmitter` base class, the `setTimeout`/`clearTimeout`
timers, and the `Buffer`/`String.fromCharCode` globals. None exist under the
Jac (CPython) runtime, so this module reproduces the surface the converted
`stdin_buffer.jac` depends on, in-process, with no Node dependency.

Contract reproduced for the converted consumers:
  - EventEmitter        -> .on(event, fn) / .emit(event, arg) / removeAllListeners
  - set_timeout(fn, ms) -> int id   (registered, fired by run_pending_timers)
  - clear_timeout(id)   -> cancel a pending timer
  - run_pending_timers()-> deterministically fire scheduled flush callbacks
  - is_buffer(x)        -> Buffer.isBuffer equivalent (bytes/bytearray)

Timers are cooperative rather than wall-clock: real pi-tui relies on the Node
event loop to fire the buffer-flush after `timeoutMs`. Under Jac there is no
ambient loop for a headless smoke, so scheduled callbacks are held and fired
explicitly via run_pending_timers(), which keeps the flush path testable and
faithful without pulling in async machinery.
"""

obj EventEmitter {
    has listeners: dict = {};

    def __init__() -> None {
        self.listeners = {};
    }

    def on(event: str, fn: any) -> EventEmitter {
        if event not in self.listeners {
            self.listeners[event] = [];
        }
        self.listeners[event].append(fn);
        return self;
    }

    def off(event: str, fn: any) -> EventEmitter {
        if event in self.listeners {
            self.listeners[event] = [f for f in self.listeners[event] if (f != fn)];
        }
        return self;
    }

    def removeAllListeners(event: any = None) -> EventEmitter {
        if (event == None) {
            self.listeners = {};
        }
        elif event in self.listeners {
            self.listeners.pop(event, None);
        }
        return self;
    }

    def emit(event: str, arg: any = None) -> bool {
        if event not in self.listeners {
            return False;
        }
        for fn in list(self.listeners[event]) {
            fn(arg);
        }
        return True;
    }
}

obj TimerQueue {
    has seq: int = 0;
    has pending: dict = {};

    def schedule(fn: any, ms: float) -> int {
        self.seq += 1;
        self.pending[self.seq] = fn;
        return self.seq;
    }

    def cancel(tid: any) -> None {
        self.pending.pop(tid, None);
    }

    def run_all() -> int {
        fired = 0;
        for tid in sorted(list(self.pending.keys())) {
            fn = self.pending.pop(tid, None);
            if fn {
                fn();
                fired += 1;
            }
        }
        return fired;
    }

    def count() -> int {
        return len(self.pending);
    }
}

glob _timerQueue = TimerQueue();

def set_timeout(fn: any, ms: float) -> int {
    return _timerQueue.schedule(fn, ms);
}

def clear_timeout(tid: any) -> None {
    _timerQueue.cancel(tid);
}

def run_pending_timers() -> int {
    return _timerQueue.run_all();
}

def pending_timer_count() -> int {
    return _timerQueue.count();
}

def is_buffer(data: any) -> bool {
    return isinstance(data, (bytes, bytearray));
}

# ---------------------------------------------------------------------------
# AbortController / AbortSignal (no Node/browser global under Jac)
# ---------------------------------------------------------------------------

obj AbortSignal {
    has aborted: bool = False;
    has _emitter: EventEmitter = EventEmitter();

    def __init__() -> None {
        self.aborted = False;
        self._emitter = EventEmitter();
    }

    def addEventListener(event: str, fn: any) -> None {
        self._emitter.on(event, fn);
    }
    def removeEventListener(event: str, fn: any) -> None {
        self._emitter.off(event, fn);
    }
}

obj:pub AbortController {
    has signal: AbortSignal = AbortSignal();

    def __init__() -> None {
        self.signal = AbortSignal();
    }

    def abort() -> None {
        if not self.signal.aborted {
            self.signal.aborted = True;
            self.signal._emitter.emit("abort", None);
        }
    }
}

# ---------------------------------------------------------------------------
# Promise (minimal, synchronous-executor shim)
# ---------------------------------------------------------------------------
# The converted sources construct `new Promise((resolve) => { ... })` purely
# to bridge a callback-based API (timers / terminal replies) into a
# thenable. There is no event loop under Jac, so this shim runs the executor
# synchronously and resolves either immediately or later when `resolve` is
# invoked by a timer callback; `.then` fires right away if already settled.

obj SimplePromise {
    has _value: any = None;
    has _resolved: bool = False;
    has _callbacks: list = [];

    def __init__() -> None {
        self._value = None;
        self._resolved = False;
        self._callbacks = [];
    }

    def _resolve(value: any = None) -> None {
        if self._resolved { return; }
        self._resolved = True;
        self._value = value;
        for cb in self._callbacks { cb(value); }
        self._callbacks = [];
    }

    def then(cb: any) -> SimplePromise {
        if self._resolved {
            cb(self._value);
        } else {
            self._callbacks.append(cb);
        }
        return self;
    }
}

def Promise(executor: any) -> SimplePromise {
    p = SimplePromise();
    executor(p._resolve);
    return p;
}

def promise_resolve(value: any = None) -> SimplePromise {
    p = SimplePromise();
    p._resolve(value);
    return p;
}
