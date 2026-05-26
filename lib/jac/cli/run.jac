"""CLI run pure functions wrapper."""

::py::
import os
import sys as _sys

_pkg = os.path.join(os.getcwd(), "lib", "jac", "cli")
if _pkg not in _sys.path:
    _sys.path.insert(0, _pkg)

from _run_toolchain import (
    resolve_run_mode,
    parse_run_args,
    format_tool_line,
    last_assistant_text,
    approval_message,
)
::py::
