"""Jac environment detection — binary, version, project layout, MCP availability."""

::py::
import os
import sys as _sys

_pkg = os.path.join(os.getcwd(), "lib", "jac", "jac")
if _pkg not in _sys.path:
    _sys.path.insert(0, _pkg)

from _doctor_toolchain import run_jac_doctor
::py::
