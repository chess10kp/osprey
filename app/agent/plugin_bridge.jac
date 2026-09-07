"""Compatibility facade for the plugin bridge public API.

Implementation responsibilities live in plugin_bridge_* modules; this module
re-exports the historical names so callers and tests keep their imports.
"""

import from .protocol { Envelope, make_envelope, is_plugin_kind }
import from .registry { ToolRegistry, register_js, unregister_extension }
import from .interactions { new_ui_queue, UiInteractionQueue }
import from .fake_host {
    FakePluginHost,
    FakeUi,
    apply_hello,
    create_fake_host,
    ensure_host,
    touch_bridge,
}
import from .plugin_bridge_support {
    _path_abspath,
    _path_dirname,
    resolve_host_mjs,
    resolve_stub_echo,
    resolve_pi_greet,
    resolve_pi_ctx_probe,
    resolve_stub_commands,
    resolve_pi_gated,
    resolve_node_bin,
    envelope_to_dict,
    envelope_from_dict,
}
import from .plugin_bridge_core {
    PluginBridge,
    create_bridge,
    _alloc_corr,
    _node_alive,
    _emit_host_status,
    invoke_tool,
    _invoke_tool_fake,
    _invoke_tool_node,
}
import from .plugin_bridge_host {
    host_status,
    maybe_reap_idle,
    ensure_node_host,
    maybe_restart_host,
    dispose_bridge,
}
import from .plugin_bridge_io {
    _write_node,
    _dispatch_inbound,
    _reader_loop,
    _ensure_io,
    _start_reader,
    _stop_reader,
    _prepare_corr,
    _wait_corr,
    _read_node,
    _read_node_until,
    _ui_queue,
    _ui_enqueue_from_env,
    _ui_send_response,
}
import from .plugin_bridge_extensions {
    load_extension,
    caps_satisfied,
    ui_cap_satisfied,
    load_extension_path,
    unload_extension,
    invoke_shortcut,
    cancel_tool,
    drain_inbox,
    invoke_command,
}
import from .plugin_bridge_traffic {
    _absorb_payload,
    list_shortcuts,
    list_labels,
    drain_model_requests,
    _absorb_pending_fake,
}
import from .plugin_bridge_hooks {
    fire_hook_data,
    _absorb_hook_results,
    _ok_verdicts,
    tool_call_gate,
    tool_result_gate,
    input_gate,
    context_gate,
    agent_start_gate,
    fire_hook,
    fire_user_bash,
    fire_project_trust,
}
import from .plugin_bridge_features {
    transform_markdown,
    drain_extension_traffic,
    set_session_name,
    resolve_ext_model,
    prepare_provider_request,
    _fake_content_lines,
    render_extension_block,
}
import from .plugin_bridge_ui {
    poll_ui_request,
    respond_ui,
    cancel_ui,
    cancel_all_ui,
}
