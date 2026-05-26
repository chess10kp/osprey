"""File mention parsing for @path and @path:10-20 extraction."""

::py::
import os
import sys as _sys

_pkg = os.path.join(os.getcwd(), "lib", "jac", "workflow")
if _pkg not in _sys.path:
    _sys.path.insert(0, _pkg)

from _file_mention_parser_toolchain import (
    FileMention,
    get_current_file_mention,
    is_valid_file_path,
    parse_file_mentions,
    parse_line_range,
    parse_mention_token,
)
::py::
