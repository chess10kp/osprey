"""Frontmatter parsing for markdown files."""

::py::
import os
import sys as _sys

_pkg = os.path.join(os.getcwd(), "lib", "jac", "orchestration")
if _pkg not in _sys.path:
    _sys.path.insert(0, _pkg)

from _frontmatter_toolchain import (
    ParsedFrontmatter,
    parse_frontmatter,
    frontmatter_string,
    frontmatter_string_list,
)
::py::
