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


def set_mode_state(next_mode: str) -> None {
    mode = next_mode;
}

def set_model_state(name: str) -> None {
    model = name;
}

def set_thinking_level_state(level: str) -> None {
    thinking_level = level;
}

def reset_turn_stats(t0: float) -> None {
    _t0 = t0;
    _n_tools = 0;
}

def bump_tool_count() -> None {
    _n_tools += 1;
}

def adopt_model_prefs(raw: dict[str, any]) -> None {
    """Adopt a successfully loaded model_prefs dict and latch the one-shot.""";
    _model_prefs = raw;
    _model_prefs_loaded = True;
}
