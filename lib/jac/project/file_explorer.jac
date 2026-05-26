"""Project file listing + token estimation for @mentions and /explorer."""

::py::
import os
import sys as _sys

_pkg = os.path.join(os.getcwd(), "lib", "jac", "project")
if _pkg not in _sys.path:
    _sys.path.insert(0, _pkg)

from _file_explorer_toolchain import (
    CHARS_PER_TOKEN,
    TOKEN_WARN_THRESHOLD,
    estimate_selection_chars,
    estimate_tokens_from_chars,
    format_token_estimate,
    list_project_files,
)
::py::
