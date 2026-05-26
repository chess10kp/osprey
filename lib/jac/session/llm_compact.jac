"""LLM compaction summary wrapping helper."""

::py::
import os
import sys as _sys

_pkg = os.path.join(os.getcwd(), "lib", "jac", "session")
if _pkg not in _sys.path:
    _sys.path.insert(0, _pkg)

from _llm_compact_toolchain import (
    wrap_compaction_summary,
)
::py::
