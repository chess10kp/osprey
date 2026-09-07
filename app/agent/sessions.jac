"""Session persistence compatibility facade.

Transcript/index persistence remains in sessions_core; export, pruning, and
latest-session helpers live in sessions_maintenance. These imports preserve
the historical agent.sessions API.
"""

import from .sessions_core {
    _last_id_ms,
    _SESSION_ID_PATTERN,
    _DEFAULT_NAME,
    _INDEX_NAME,
    _LEGACY_INDEX_NAME,
    _TRANSCRIPT_SUFFIX,
    _path_abspath,
    _path_dirname,
    _sessions_dir,
    _session_path,
    _index_path,
    is_valid_session_id,
    _next_epoch_ms,
    new_session_id,
    _iso_from_ms,
    _now_iso,
    _read_json,
    _write_json,
    _is_record,
    _is_index_entry,
    _entry_sort_key,
    _newest_first,
    _read_index,
    _write_index,
    _upsert_index_entry,
    _scan_directory,
    save_session,
    get_session_record,
    load_session,
    list_sessions,
    rename_session,
    delete_session,
}
import from .sessions_maintenance {
    _iso_to_epoch,
    prune_sessions,
    latest_session_id,
    export_session,
}
