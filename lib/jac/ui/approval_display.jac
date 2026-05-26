"""Approval display — human-readable summaries for tool approval UI."""

::py::
import os
import sys as _sys

_pkg = os.path.join(os.getcwd(), "lib", "jac", "ui")
if _pkg not in _sys.path:
    _sys.path.insert(0, _pkg)

from _approval_display_toolchain import format_approval_display
::py::
