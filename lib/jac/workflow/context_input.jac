"""Context input expansion — @file mentions and !command prefixes."""

::py::
import os
import sys as _sys

_pkg = os.path.join(os.getcwd(), "lib", "jac", "workflow")
if _pkg not in _sys.path:
    _sys.path.insert(0, _pkg)

from _context_input_toolchain import (
    load_file_slice,
    run_inline_command,
    expand_context_input_sync,
)
::py::
