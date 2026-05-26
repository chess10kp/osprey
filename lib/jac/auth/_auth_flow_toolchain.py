"""Auth flow state machine — pure functions for login flow transitions.

Port of src/auth/auth-flow.ts. The reactive subscription system (listeners,
AbortController, promise resolvers) stays in TS. This module provides
pure validation, filtering, formatting, and state-transition functions.
"""

from __future__ import annotations

import copy
from typing import Any, Dict, List, Optional


# ── Validation ──────────────────────────────────────────────────────────

def validate_provider_entry(entry: Any) -> Optional[Dict[str, Any]]:
    """Validate and normalise a provider entry dict. Returns None on failure."""
    if not isinstance(entry, dict):
        return None
    id_ = entry.get("id")
    display = entry.get("displayName")
    auth_type = entry.get("authType")
    if not isinstance(id_, str) or not id_:
        return None
    if not isinstance(display, str) or not display:
        return None
    if auth_type not in ("oauth", "api_key", "env"):
        return None
    return {
        "id": id_,
        "displayName": display,
        "authType": auth_type,
        "configured": bool(entry.get("configured", False)),
        "modelCount": int(entry.get("modelCount", 0)),
    }


def validate_model_entry(entry: Any) -> Optional[Dict[str, Any]]:
    """Validate and normalise a model entry dict. Returns None on failure."""
    if not isinstance(entry, dict):
        return None
    provider = entry.get("provider")
    model_id = entry.get("modelId")
    display = entry.get("displayName")
    if not isinstance(provider, str) or not provider:
        return None
    if not isinstance(model_id, str) or not model_id:
        return None
    if not isinstance(display, str) or not display:
        return None
    return {
        "provider": provider,
        "modelId": model_id,
        "displayName": display,
    }


# ── Filtering ──────────────────────────────────────────────────────────

def filter_providers_by_query(
    providers: List[Dict[str, Any]],
    query: str,
) -> List[Dict[str, Any]]:
    """Filter provider entries by a search query (case-insensitive substring)."""
    if not query:
        return list(providers)
    q = query.lower()
    return [
        p for p in providers
        if q in p.get("id", "").lower()
        or q in p.get("displayName", "").lower()
    ]


def filter_models_by_query(
    models: List[Dict[str, Any]],
    query: str,
    provider_filter: Optional[str] = None,
) -> List[Dict[str, Any]]:
    """Filter model entries by query and optional provider filter."""
    result = models
    if provider_filter:
        result = [m for m in result if m.get("provider") == provider_filter]
    if query:
        q = query.lower()
        result = [
            m for m in result
            if q in m.get("modelId", "").lower()
            or q in m.get("displayName", "").lower()
            or q in m.get("provider", "").lower()
        ]
    return result


# ── Formatting ─────────────────────────────────────────────────────────

def format_auth_provider_label(entry: Dict[str, Any]) -> str:
    """Format a human-readable label for a provider entry."""
    name = entry.get("displayName", entry.get("id", "unknown"))
    auth_type = entry.get("authType", "")
    configured = "✓" if entry.get("configured") else " "
    model_count = entry.get("modelCount", 0)
    auth_label = {"oauth": "OAuth", "api_key": "API Key", "env": "Env"}.get(auth_type, auth_type)
    return f"[{configured}] {name} ({auth_label}, {model_count} models)"


def format_model_label(entry: Dict[str, Any]) -> str:
    """Format a human-readable label for a model entry."""
    display = entry.get("displayName", entry.get("modelId", "unknown"))
    provider = entry.get("provider", "")
    model_id = entry.get("modelId", "")
    if provider:
        return f"{display} ({provider}/{model_id})"
    return display


# ── State machine ──────────────────────────────────────────────────────

def initial_auth_flow_state() -> Dict[str, Any]:
    """Return the initial auth flow state (idle step)."""
    return {"step": {"kind": "idle"}}


def transition_auth_flow(
    current_state: Dict[str, Any],
    action: str,
    payload: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    """Pure state machine transition.

    Args:
        current_state: Current auth flow state dict with a ``step`` key.
        action: Action name string (e.g. ``"open_provider_picker"``).
        payload: Optional dict with action-specific data.

    Returns:
        New state dict. Does not mutate *current_state*.
    """
    p = payload or {}
    step = current_state.get("step", {})

    if action == "open_provider_picker":
        providers = p.get("providers", [])
        # Validate each provider entry
        valid = []
        for entry in providers:
            v = validate_provider_entry(entry)
            if v is not None:
                valid.append(v)
        return {"step": {"kind": "provider_picker", "providers": valid, "query": ""}}

    if action == "open_model_picker":
        models = p.get("models", [])
        valid = []
        for entry in models:
            v = validate_model_entry(entry)
            if v is not None:
                valid.append(v)
        return {"step": {"kind": "model_picker", "models": valid, "providerFilter": None, "query": ""}}

    if action == "set_logging_in":
        return {
            "step": {
                "kind": "logging_in",
                "providerId": p.get("providerId", ""),
                "status": p.get("status", ""),
            },
        }

    if action == "set_browser_auth":
        result_step: Dict[str, Any] = {
            "kind": "browser_auth",
            "providerId": p.get("providerId", ""),
            "url": p.get("url", ""),
        }
        if p.get("instructions"):
            result_step["instructions"] = p["instructions"]
        return {"step": result_step}

    if action == "set_prompt":
        return {
            "step": {
                "kind": "prompt",
                "providerId": p.get("providerId", ""),
                "message": p.get("message", ""),
                "placeholder": p.get("placeholder", ""),
            },
        }

    if action == "set_manual_code":
        return {
            "step": {
                "kind": "manual_code",
                "providerId": p.get("providerId", ""),
            },
        }

    if action == "set_select":
        return {
            "step": {
                "kind": "select",
                "providerId": p.get("providerId", ""),
                "message": p.get("message", ""),
                "options": p.get("options", []),
            },
        }

    if action == "set_api_key_input":
        return {
            "step": {
                "kind": "api_key_input",
                "providerId": p.get("providerId", ""),
            },
        }

    if action == "set_logged_in":
        return {
            "step": {
                "kind": "logged_in",
                "providerId": p.get("providerId", ""),
                "nextStep": p.get("nextStep", "done"),
            },
        }

    if action == "set_error":
        result_step = {
            "kind": "error",
            "message": p.get("message", ""),
        }
        if p.get("providerId"):
            result_step["providerId"] = p["providerId"]
        return {"step": result_step}

    if action == "set_idle":
        return {"step": {"kind": "idle"}}

    if action == "update_query":
        query = p.get("query", "")
        if step.get("kind") == "provider_picker":
            new_step = copy.deepcopy(step)
            new_step["query"] = query
            return {"step": new_step}
        if step.get("kind") == "model_picker":
            new_step = copy.deepcopy(step)
            new_step["query"] = query
            return {"step": new_step}
        # Query update on non-picker step: no-op
        return copy.deepcopy(current_state)

    if action == "update_provider_filter":
        provider_filter = p.get("providerFilter")
        if step.get("kind") == "model_picker":
            new_step = copy.deepcopy(step)
            new_step["providerFilter"] = provider_filter
            return {"step": new_step}
        return copy.deepcopy(current_state)

    if action == "cancel":
        return {"step": {"kind": "idle"}}

    if action == "reset":
        return initial_auth_flow_state()

    # Unknown action: return unchanged copy
    return copy.deepcopy(current_state)
