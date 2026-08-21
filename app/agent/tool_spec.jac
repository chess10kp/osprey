"""Shared tool schema - no I/O, no transport deps.

Kept separate from llm.jac so registry/tools can import ToolSpec without
pulling httpx (llm transport).
"""

import from typing { Callable }


obj ToolSpec {
    has name: str,
        description: str = "",
        parameters: dict = {},
        handler: Callable | None = None;
}
