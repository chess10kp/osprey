"""Project initializer wrapper."""

::py::
import os
import sys as _sys

_pkg = os.path.join(os.getcwd(), "lib", "jac", "project")
if _pkg not in _sys.path:
    _sys.path.insert(0, _pkg)

from _project_init_toolchain import (
    analyze_project,
    generate_agents_md,
    run_project_init,
)
::py::
