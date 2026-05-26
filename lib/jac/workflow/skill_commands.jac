"""Skill command catalog formatting."""

::py::
import os
import sys as _sys

_pkg = os.path.join(os.getcwd(), "lib", "jac", "workflow")
if _pkg not in _sys.path:
    _sys.path.insert(0, _pkg)

from _skill_commands_toolchain import format_skill_command_catalog
::py::
