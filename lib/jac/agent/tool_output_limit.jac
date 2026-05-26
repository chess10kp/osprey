"""Tool output limit helpers (50 KiB UTF-8 safe truncation)."""

::py::
import os
import sys as _sys

_pkg = os.path.join(os.getcwd(), "lib", "jac", "agent")
if _pkg not in _sys.path:
    _sys.path.insert(0, _pkg)

from _tool_output_limit_toolchain import (
    MAX_TOOL_OUTPUT_BYTES,
    truncate_tool_output,
    truncate_tool_payload,
)
::py::
