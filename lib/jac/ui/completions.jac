"""Slash-command and @file autocomplete suggestions."""

::py::
import os
import sys as _sys

_pkg = os.path.join(os.getcwd(), "lib", "jac", "ui")
if _pkg not in _sys.path:
    _sys.path.insert(0, _pkg)

from _completions_toolchain import (
    get_suggestions,
    get_file_suggestions,
    sort_and_map,
    sort_and_map_commands,
)
::py::
