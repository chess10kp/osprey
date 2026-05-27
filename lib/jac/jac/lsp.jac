"""LSP configuration helpers — .jackal + .pi-lsp.json resolution."""

::py::
import os
import sys as _sys

_pkg = os.path.join(os.getcwd(), "lib", "jac", "jac")
if _pkg not in _sys.path:
    _sys.path.insert(0, _pkg)

from _lsp_toolchain import (
    find_pi_lsp_config_path,
    load_pi_lsp_config,
    resolve_lsp_config,
)
::py::
