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
        parameters: dict[str, any] = {},
        # Native-safe tool ABI: handlers receive one decoded argument
        # dictionary instead of dynamically unpacked keyword arguments.
        handler: Callable[[dict[str, any]], str] | None = None;
}


"""Factory for ToolSpec, callable from server-codespace consumers.

After the native pin, the ToolSpec constructor itself is not reachable from
server code (native obj classes have no Python-side mirror), but a plain
native function call - args in, obj out - is. All production constructions
go through this seam; direct ToolSpec(...) calls survive only in test
annexes, which run pre-seal.
"""
def make_tool_spec(
    name: str,
    description: str = "",
    parameters: dict[str, any] = {},
    handler: Callable[[dict[str, any]], str] | None = None,
) -> ToolSpec {
    return ToolSpec(
        name=name,
        description=description,
        parameters=parameters,
        handler=handler,
    );
}
