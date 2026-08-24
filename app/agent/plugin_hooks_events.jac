"""Cheap Pi lifecycle events (user_bash, project_trust) — seam module.

The Jac importer resolves `<stem>.test.jac` as the same-stem annex of this
module, so this base file carries the shared imports; the tests live in
plugin_hooks_events.test.jac.

Firing capability: fire_user_bash / fire_project_trust in agent.plugin_bridge
wrap the generic fire_hook pass-through (hook_fire -> hook_done). The Node
shim dispatches hook_fire to listeners registered under ANY event name —
there is no allowlist — so arbitrary lifecycle events reach extensions
end-to-end once the session calls these helpers.
"""

import from .plugin_bridge {
    create_bridge,
    ensure_node_host,
    load_extension_path,
    dispose_bridge,
    fire_hook,
    fire_user_bash,
    fire_project_trust,
    PluginBridge,
}
import from .fake_host {
    register_fake_listener,
}
import from .registry { create_registry }
import os;
