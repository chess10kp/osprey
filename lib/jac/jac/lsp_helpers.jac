"""LSP helper pure functions — parse, extract, format."""

::py::
import os
import sys as _sys

_pkg = os.path.join(os.getcwd(), "lib", "jac", "jac")
if _pkg not in _sys.path:
    _sys.path.insert(0, _pkg)

from _lsp_helpers_toolchain import (
    parse_check_output,
    extract_symbol,
    escape_regex,
    format_lsp_diagnostics,
    format_hover_info,
    format_locations,
)
::py::
