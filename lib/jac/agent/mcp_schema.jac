"""MCP schema coercion wrapper."""

::py::
import os
import sys as _sys

_pkg = os.path.join(os.getcwd(), "lib", "jac", "agent")
if _pkg not in _sys.path:
    _sys.path.insert(0, _pkg)

from _mcp_schema_toolchain import (
    mcp_input_schema_to_parameters,
    coerce_by_schema,
    validate_and_coerce_args,
)
::py::
