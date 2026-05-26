"""Session index — list, load, save, delete, and prune sessions."""

::py::
import os
import sys as _sys

_pkg = os.path.join(os.getcwd(), "lib", "jac", "session")
if _pkg not in _sys.path:
    _sys.path.insert(0, _pkg)

from _session_index_toolchain import (
    SessionIndexEntry,
    SessionRecord,
    delete_session,
    get_last_session,
    is_index_entry,
    is_session_record,
    is_valid_session_id,
    list_sessions,
    load_session_by_id,
    migrate_legacy_latest,
    prune_sessions,
    read_json_file,
    rebuild_index,
    resolve_session_target,
    save_session_record,
    write_json_file,
)
::py::
