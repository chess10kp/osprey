"""Session permissions — pattern matching and approval evaluation."""

::py::
import os
import sys as _sys

_pkg = os.path.join(os.getcwd(), "lib", "jac", "agent")
if _pkg not in _sys.path:
    _sys.path.insert(0, _pkg)

from _session_permissions_toolchain import (
    match_pattern,
    evaluate_permission_patterns,
    load_always_allow_tools,
    load_permission_patterns,
    needs_tool_approval,
)
::py::
