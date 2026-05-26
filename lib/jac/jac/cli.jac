"""Unified Jac CLI helpers — subprocess check/format/test without MCP round-trip."""

::py::
import os
import sys as _sys

_pkg = os.path.join(os.getcwd(), "lib", "jac", "jac")
if _pkg not in _sys.path:
    _sys.path.insert(0, _pkg)

from _cli_toolchain import (
    parse_jac_check_output,
    fingerprint_errors,
    find_jac_binary,
    format_diagnostics,
    run_jac_command,
    run_jac_check,
    run_jac_format,
    run_jac_test,
    run_jac_run_file,
)
::py::
