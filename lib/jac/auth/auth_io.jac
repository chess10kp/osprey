"""Auth file I/O helpers."""

::py::
import os
import sys as _sys

_pkg = os.path.join(os.getcwd(), "lib", "jac", "auth")
if _pkg not in _sys.path:
    _sys.path.insert(0, _pkg)

from _auth_io_toolchain import (
    resolve_auth_path,
    load_auth_file,
    save_auth_file,
    get_auth_status,
)
::py::
