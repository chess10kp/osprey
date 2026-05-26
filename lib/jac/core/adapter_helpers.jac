"""Adapter pure helpers — context window resolution and session storage path."""

::py::
import os
import sys as _sys

_pkg = os.path.join(os.getcwd(), "lib", "jac", "core")
if _pkg not in _sys.path:
    _sys.path.insert(0, _pkg)

from _adapter_helpers_toolchain import (
    resolve_context_max,
    session_storage_dir,
)
::py::
