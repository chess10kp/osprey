"""Mermaid ASCII renderer — renders simple Mermaid diagrams as ASCII art."""

::py::
import os
import sys as _sys

_pkg = os.path.join(os.getcwd(), "lib", "jac", "render")
if _pkg not in _sys.path:
    _sys.path.insert(0, _pkg)

from _mermaid_render_toolchain import (
    detect_diagram_type,
    parse_flowchart,
    render_flowchart_ascii,
    render_mermaid_ascii,
)
::py::
