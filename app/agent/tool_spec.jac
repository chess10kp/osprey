"""Shared tool schema - no I/O, no transport deps.

Kept separate from llm.jac so registry/tools can import ToolSpec without
pulling httpx (llm transport).
"""



# Shared safety caps used by both tool execution and the ReAct history.
glob MAX_TOOL_RESULT: int = 50_000,
     MAX_SEARCH_RESULTS: int = 100;


obj ToolSpec {
    has name: str,
        description: str = "",
        parameters: dict = {},
        handler: Callable | None = None;
}
