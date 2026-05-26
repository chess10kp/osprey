"""Gitignore matcher for project file discovery."""

::py::
import os
import sys as _sys

_pkg = os.path.join(os.getcwd(), "lib", "jac", "project")
if _pkg not in _sys.path:
    _sys.path.insert(0, _pkg)

from _gitignore_toolchain import (
    DEFAULT_IGNORE_DIRS,
    load_gitignore,
)
::py::
