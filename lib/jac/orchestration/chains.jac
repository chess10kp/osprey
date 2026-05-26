"""Chain workflow discovery, loading, and parsing."""

::py::
import os
import sys as _sys

_pkg = os.path.join(os.getcwd(), "lib", "jac", "orchestration")
if _pkg not in _sys.path:
    _sys.path.insert(0, _pkg)

from _chains_toolchain import (
    chain_dirs_exist,
    discover_chain_dirs,
    format_chain_catalog,
    get_chain,
    list_chain_files,
    list_chains,
    load_chains,
    parse_chain_markdown,
    parse_step_body,
)
::py::
