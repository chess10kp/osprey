"""Web tools wrapper."""

::py::
import os
import sys as _sys

_pkg = os.path.join(os.getcwd(), "lib", "jac", "agent")
if _pkg not in _sys.path:
    _sys.path.insert(0, _pkg)

from _web_tools_toolchain import (
    brave_api_key,
    assert_safe_fetch_url,
    html_to_readable_text,
    format_web_search_results,
    parse_brave_search_response,
    search_web,
    fetch_web_page,
)
::py::
