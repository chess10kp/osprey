"""Skills loader wrapper."""

::py::
import os
import sys as _sys

_pkg = os.path.join(os.getcwd(), "lib", "jac", "project")
if _pkg not in _sys.path:
    _sys.path.insert(0, _pkg)

from _skills_toolchain import (
    load_skills_from_dir,
    load_jackal_skills,
    format_skills_for_prompt,
    append_skills_to_prompt,
    expand_skill_command,
    load_skill_by_dir,
    skill_read_allowlist,
)
::py::
