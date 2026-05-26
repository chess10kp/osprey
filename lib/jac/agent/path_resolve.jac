"""Path resolution and safety helpers for tool execution."""

::py::
import os
import sys as _sys

_pkg = os.path.join(os.getcwd(), "lib", "jac", "agent")
if _pkg not in _sys.path:
    _sys.path.insert(0, _pkg)

from _path_resolve_toolchain import (
    safe_resolve,
    resolve_read_path,
    format_post_write_message,
)
::py::
