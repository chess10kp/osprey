"""Jackal Jac differentiator workflows — OSP, explain, diagram-to-model prompts."""

::py::
import os
import sys as _sys

_pkg = os.path.join(os.getcwd(), "lib", "jac", "jac")
if _pkg not in _sys.path:
    _sys.path.insert(0, _pkg)

from _workflows_toolchain import (
    resolve_package_root,
    load_skill_content,
    render_prompt_template,
    build_osp_prompt,
    build_convert_python_prompt,
    build_idiom_review_prompt,
    build_explain_prompt,
    build_diagram_to_model_prompt,
)
::py::
