"""Auto-compact — automatic context compaction triggered at context % threshold."""

::py::
import os
import sys as _sys

_pkg = os.path.join(os.getcwd(), "lib", "jac", "session")
if _pkg not in _sys.path:
    _sys.path.insert(0, _pkg)

from _auto_compact_toolchain import (
    AutoCompactConfig,
    AutoCompactResult,
    CompactStrategy,
    DEFAULT_AUTO_COMPACT,
    build_llm_summary_prompt,
    build_mechanical_summary,
    resolve_auto_compact_config,
    should_auto_compact,
)
::py::
