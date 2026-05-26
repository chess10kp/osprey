"""Subagent catalog — discovery, loading, tool normalization."""

::py::
import os
import sys as _sys

_pkg = os.path.join(os.getcwd(), "lib", "jac", "orchestration")
if _pkg not in _sys.path:
    _sys.path.insert(0, _pkg)

from _subagents_toolchain import (
    SUBAGENT_TOOL_ALIASES,
    EXCLUDED_SUBAGENT_TOOLS,
    resolve_jackal_root,
    is_existing_dir,
    list_markdown_files,
    load_agent_file,
    load_agents_from_dir,
    discover_subagent_dirs,
    load_subagents,
    list_subagents,
    get_subagent,
    load_settings_model_overrides,
    load_project_model_overrides,
    normalize_allowed_tool_names,
    filter_tools_for_subagent,
    format_subagent_catalog,
)
::py::
