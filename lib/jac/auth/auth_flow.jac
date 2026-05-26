"""Auth flow state machine — pure functions for login transitions."""

::py::
import os
import sys as _sys

_pkg = os.path.join(os.getcwd(), "lib", "jac", "auth")
if _pkg not in _sys.path:
    _sys.path.insert(0, _pkg)

from _auth_flow_toolchain import (
    validate_provider_entry,
    validate_model_entry,
    filter_providers_by_query,
    filter_models_by_query,
    format_auth_provider_label,
    format_model_label,
    initial_auth_flow_state,
    transition_auth_flow,
)
::py::
