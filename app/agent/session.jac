"""Compatibility facade for the agent session API.

Implementation is split by responsibility across session_state, session_config,
session_lifecycle, session_turn, and session_commands. Keep this module's
exports stable: callers import the session API from agent.session.
"""

import from .session_state {
    SessionPlugins,
    history,
    show_stats,
    mode,
    plugins,
    get_model_state,
    get_thinking_level_state,
    set_model_state,
}
import from .session_config {
    set_mode,
    get_mode,
    model_preferences,
    set_model as _set_model,
    set_thinking_level as _set_thinking_level,
    clear_history,
}

glob model: str = get_model_state(),
     thinking_level: str = get_thinking_level_state();

"""Read live scalar session state for callers that outlive the split facade.
The exported scalar names are maintained by the facade setters for
compatibility; new code should use these accessors for live state."""
def set_model(name: str) -> str {
    result = _set_model(name);
    if result == name {
        model = name;
    }
    return result;
}

def set_thinking_level(level: str) -> str {
    result = _set_thinking_level(level);
    if result == level {
        thinking_level = level;
    }
    return result;
}

def get_model() -> str {
    return get_model_state();
}

"""Restore a persisted model reference without performing a live credential
check; the next turn still reports provider errors before network I/O."""
def restore_model(name: str) -> str {
    set_model_state(name);
    model = name;
    return name;
}

def get_thinking_level() -> str {
    return get_thinking_level_state();
}
import from .session_lifecycle {
    session_boot,
    wait_extensions_ready,
    enqueue_prompt,
    drain_prompt_queue,
    session_dispose,
    extensions_status,
}
import from .session_turn {
    render_event,
    relay_tool_hooks,
    run_turn,
    _apply_extension_traffic,
}
import from .session_commands {
    get_history,
    restore_history,
    set_current_session_id,
    cancel_active_turn,
    list_commands,
    run_command,
    run_extension_shortcut,
    list_extension_shortcuts,
    list_extension_labels,
    json_event,
}

# Preserve the dependency names historically visible through agent.session.
import from .llm {
    Transport,
    react_loop,
    make_transport,
    make_ext_transport,
    TurnCancel,
    provider_for,
    credential_error,
}
import from .compaction {
    load_project_config,
    resolve_auto_compact_config,
    compute_context_usage,
    should_auto_compact,
    build_mechanical_summary,
    summarize_for_compaction,
}
import from .tools { default_registry }
import from .system { SYSTEM_PROMPT }
import from .modes { DEV_MODES, system_prompt_for_mode }
import from .plugin_bridge {
    PluginBridge,
    create_bridge,
    dispose_bridge,
    host_status,
    ensure_node_host,
    load_extension_path,
    invoke_command,
    invoke_shortcut,
    fire_user_bash,
    fire_hook,
    transform_markdown,
    drain_extension_traffic,
    agent_start_gate,
    input_gate,
    render_extension_block,
    list_shortcuts,
    list_labels,
    drain_model_requests,
    fire_project_trust,
}
import from .registry { ToolRegistry, register_native, get_tool }
import from .mcp {
    McpClient,
    create_mcp_client,
    mcp_start,
    mcp_list_tools,
    mcp_stop,
}
import from .extensions {
    ExtensionDecl,
    ExtensionStatus,
    load_extension_decls,
    node_sidecar_decls,
    extensions_label,
    resolve_decl_path,
    decl_from_dict,
}
import from .sessions {
    save_session,
    list_sessions,
    latest_session_id,
    get_session_record,
    export_session,
    new_session_id,
    is_valid_session_id,
}
