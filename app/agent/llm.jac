"""Jackal model layer compatibility facade.

Transport, provider routing, and the ReAct loop live in focused submodules;
these imports preserve the historical agent.llm API.
"""

import from .llm_transport {
    Transport,
    ProviderTransport,
    PluginBridge,
    PROVIDER_ROUTES,
    provider_for,
    credential_error,
    make_transport,
    make_ext_transport,
}
import from .llm_loop {
    ToolSpec,
    MAX_TOOL_RESULT,
    ToolRegistry,
    TurnCancel,
    react_loop,
    _tool_defs,
    _find_spec,
    _is_transient_error,
    _cap_tool_result,
    _notify_message_end,
}
