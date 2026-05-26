"""Tool input normalization and compact display labels for the Ink transcript."""

::py::
import os
import sys as _sys

_pkg = os.path.join(os.getcwd(), "lib", "jac", "core")
if _pkg not in _sys.path:
    _sys.path.insert(0, _pkg)

from _tool_summary_toolchain import (
    normalize_tool_input,
    tool_input_field,
    tool_bash_command,
    tool_file_path,
    format_tool_summary,
    enrich_tool_input_from_result,
    tool_event_input,
)
::py::
