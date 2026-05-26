"""System prompt loading — explicit > project files > fallback."""

::py::
import os
import sys as _sys

_pkg = os.path.join(os.getcwd(), "lib", "jac", "agent")
if _pkg not in _sys.path:
    _sys.path.insert(0, _pkg)

from _system_prompt_toolchain import load_system_prompt_base
::py::
