"""Live-shell demo entry point — the composition root for the demo binary.

Runs server-placed on purpose: the live loop sits on the terminal/FFI
frontier (`ProcessTerminal` methods, renderer path) that still demotes, so
the entry block must reach a Python-only callee — a native `with entry`
cannot call a demoted function (E5092 hard failure, not a seam note).

  JACPATH=. jac run ui/demo_entry.jac
"""

import from "libc.so.6" { def isatty(fd: i32) -> i32; }

import from .demo_live_shell { run_live_shell_demo }


with entry {
    if isatty(0) != 1 or isatty(1) != 1 {
        print("demo_live_shell needs a real TTY.");
        print("  JACPATH=. jac run ui/demo_entry.jac");
        raise SystemExit(1);
    }
    run_live_shell_demo();
}
