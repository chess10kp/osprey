"""Minimal Jackal MCP server implemented in Jac.

This intentionally exposes no tools/resources/prompts.
"""

import asyncio;
import sys;

obj JackalMcpServer {
    has transport: str = "stdio";

    """Start the MCP server with stdio transport."""
    def start -> None;
}

impl JackalMcpServer.start -> None {
    asyncio.run(_async_start(self));
}

async def _async_start(srv: JackalMcpServer) {
    try {
        import from mcp.server { Server }
        import from mcp.server.stdio { stdio_server }
    } except ImportError as e {
        sys.stderr.write(
            f"jackal simple MCP requires python package 'mcp'. Import failed: {e}\n"
        );
        sys.exit(1);
    }

    server = Server(
        "jackal-simple",
        instructions=(
            "Jackal simple MCP server. "
            "No tools/resources/prompts are exposed in this minimal build."
        )
    );

    @server.list_tools()
    async def handle_list_tools -> list {
        return [];
    }

    @server.list_resources()
    async def handle_list_resources -> list {
        return [];
    }

    @server.list_prompts()
    async def handle_list_prompts -> list {
        return [];
    }

    async with stdio_server() as (read_stream, write_stream) {
        await server.run(
            read_stream,
            write_stream,
            server.create_initialization_options()
        );
    }
}

with entry {
    srv = JackalMcpServer();
    srv.start();
}
