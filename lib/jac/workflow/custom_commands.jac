"""Custom commands — load and expand .jackal/commands/*.md."""

::py::
import os
import sys as _sys

_pkg = os.path.join(os.getcwd(), "lib", "jac", "workflow")
if _pkg not in _sys.path:
    _sys.path.insert(0, _pkg)

from _custom_commands_toolchain import (
    custom_command_slash_names,
    expand_command_template,
    expand_custom_command,
    format_custom_command_catalog,
    load_custom_commands,
    resolve_custom_command_input,
    try_expand_slash_command,
)
::py::
