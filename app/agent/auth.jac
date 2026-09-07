"""Provider credentials and login flow compatibility facade.

Focused implementations are split into credential storage, picker/display
helpers, flow transitions, and runtime-owned network seams. These imports
preserve the historical agent.auth API.
"""

import from .auth_credentials {
    AUTH_FILE_NAME,
    DEFAULT_AGENT_DIR_NAME,
    KNOWN_AUTH_TYPES,
    OAUTH_REQUIRED_KEYS,
    _path_abspath,
    _path_expanduser,
    _path_dirname,
    _file_chmod,
    resolve_auth_path,
    load_auth_file,
    save_auth_file,
    validate_credential,
    credential_get,
    credential_set,
    credential_remove,
    has_credential,
    now_ms,
    is_expired,
    stored_api_key,
    get_auth_status,
}
import from .auth_display {
    redact_secret,
    redact_credential,
    validate_provider_entry,
    login_kind,
    needs_oauth,
    validate_model_entry,
    filter_providers_by_query,
    filter_models_by_query,
    format_provider_label,
    format_model_label,
}
import from .auth_flow {
    initial_auth_flow_state,
    step_is_pending,
    transition_auth_flow,
}
import from .auth_network {
    oauth_refresh_credentials,
    oauth_start_login,
}
