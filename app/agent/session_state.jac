"""Shared mutable state for the agent session compatibility facade."""

import os;
import from .plugin_bridge { PluginBridge }
import from .mcp { McpClient }


"""Mutable plugin/session control-plane state."""
obj SessionPlugins {
    has session_id: str = "session",
        cwd: str = "",
        bridge: PluginBridge | None = None,
        reg: any = None,
        decls: list[any] = [],
        loaded: int = 0,
        total: int = 0,
        ready: bool = True,
        phase: str = "idle",
        detail: str = "",
        t_interactive: float = 0.0,
        t_ext_ready: float = 0.0,
        prompt_queue: list[str] = [],
        warm_future: any = None,
        wait_budget_s: float = 5.0,
        commands: dict[str, any] = {},
        interactive_ui: bool = False,
        active_cancel: any = None,
        mcp_clients: dict[str, McpClient] = {},
        mcp_tools: int = 0;
}


glob history: list[dict[str, any]] = [],
     show_stats: bool = True,
     model: str = os.environ.get("JACKAL_MODEL", "openrouter/anthropic/claude-sonnet-5"),
     thinking_level: str = "",
     mode: str = "normal",
     plugins: SessionPlugins = SessionPlugins(),
     _t0: float = 0.0,
     _n_tools: int = 0,
     _model_prefs: dict[str, any] = {},
     _model_prefs_loaded: bool = False;
