"""Subagent runner pure logic — summary extraction, chain step building."""

::py::
import os
import sys as _sys

_pkg = os.path.join(os.getcwd(), "lib", "jac", "orchestration")
if _pkg not in _sys.path:
    _sys.path.insert(0, _pkg)

from _subagent_runner_toolchain import (
    MAX_PARALLEL_SUBAGENTS,
    extract_assistant_summary,
    count_tool_calls,
    substitute_chain_template,
    build_step_prompt,
    build_subagent_tool_description,
)
::py::
