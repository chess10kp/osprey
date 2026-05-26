"""Jac toolchain types — re-export fingerprint from cli (::py::)."""

::py::
import os
import sys as _sys

_pkg = os.path.join(os.getcwd(), "lib", "jac", "jac")
if _pkg not in _sys.path:
    _sys.path.insert(0, _pkg)

from _cli_toolchain import fingerprint_errors
::py::
