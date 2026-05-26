"""Agent busy detection — pure snapshot predicate."""

::py::
import os
import sys as _sys

_pkg = os.path.join(os.getcwd(), "lib", "jac", "core")
if _pkg not in _sys.path:
    _sys.path.insert(0, _pkg)

from _agent_busy_toolchain import (
    is_agent_busy,
)
::py::
