"""Project config — .jackal walk-up loader and mode resolver."""

::py::
import os
import sys as _sys

_pkg = os.path.join(os.getcwd(), "lib", "jac", "config")
if _pkg not in _sys.path:
    _sys.path.insert(0, _pkg)

from _project_config_toolchain import (
    VALID_MODES,
    find_config_path,
    load_project_config,
    resolve_default_mode,
)
::py::
