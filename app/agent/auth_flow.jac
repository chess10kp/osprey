"""Pure login-flow state machine for the auth UI."""

import copy;
import from .auth_credentials { KNOWN_AUTH_TYPES }
import from .auth_display { validate_provider_entry, validate_model_entry }

# ── Login flow state machine (from _auth_flow_toolchain.py) ─────────────


"""Initial flow state: the idle step."""
def initial_auth_flow_state() -> dict {
    return {"step": {"kind": "idle"}};
}


"""Steps that block on user input (prompt/manual_code/select/api_key_input).
The UI layer attaches promise resolvers to these; cancel mid-flow means
abandoning such a step and returning to idle."""
def step_is_pending(state: dict) -> bool {
    kind = state.get("step", {}).get("kind", "");
    return kind in ["prompt", "manual_code", "select", "api_key_input"];
}


"""Pure transition table for the login flow. Actions:
open_provider_picker, open_model_picker, set_logging_in, set_browser_auth,
set_prompt, set_manual_code, set_select, set_api_key_input, set_logged_in,
set_error, set_idle, update_query, update_provider_filter, cancel, reset.
Unknown actions return an unchanged copy. Never mutates current_state."""
def transition_auth_flow(current_state: dict, action: str, payload: dict | None = None) -> dict {
    p = payload if payload is not None else {};
    step = current_state.get("step", {});

    if action == "open_provider_picker" {
        incoming: list = p.get("providers", []);
        valid: list = [];
        for item in incoming {
            v = validate_provider_entry(item);
            if v is not None {
                valid.append(v);
            }
        }
        return {"step": {"kind": "provider_picker", "providers": valid, "query": ""}};
    }

    if action == "open_model_picker" {
        incoming: list = p.get("models", []);
        valid: list = [];
        for item in incoming {
            v = validate_model_entry(item);
            if v is not None {
                valid.append(v);
            }
        }
        return {"step": {"kind": "model_picker", "models": valid,
                         "providerFilter": None, "query": ""}};
    }

    if action == "set_logging_in" {
        return {"step": {"kind": "logging_in",
                         "providerId": p.get("providerId", ""),
                         "status": p.get("status", "")}};
    }

    if action == "set_browser_auth" {
        result_step: dict = {
            "kind": "browser_auth",
            "providerId": p.get("providerId", ""),
            "url": p.get("url", ""),
        };
        if p.get("instructions") {
            result_step["instructions"] = p["instructions"];
        }
        return {"step": result_step};
    }

    if action == "set_prompt" {
        return {"step": {"kind": "prompt",
                         "providerId": p.get("providerId", ""),
                         "message": p.get("message", ""),
                         "placeholder": p.get("placeholder", "")}};
    }

    if action == "set_manual_code" {
        return {"step": {"kind": "manual_code",
                         "providerId": p.get("providerId", "")}};
    }

    if action == "set_select" {
        return {"step": {"kind": "select",
                         "providerId": p.get("providerId", ""),
                         "message": p.get("message", ""),
                         "options": p.get("options", [])}};
    }

    if action == "set_api_key_input" {
        return {"step": {"kind": "api_key_input",
                         "providerId": p.get("providerId", "")}};
    }

    if action == "set_logged_in" {
        return {"step": {"kind": "logged_in",
                         "providerId": p.get("providerId", ""),
                         "nextStep": p.get("nextStep", "done")}};
    }

    if action == "set_error" {
        result_step: dict = {"kind": "error", "message": p.get("message", "")};
        if p.get("providerId") {
            result_step["providerId"] = p["providerId"];
        }
        return {"step": result_step};
    }

    if action == "set_idle" {
        return {"step": {"kind": "idle"}};
    }

    if action == "update_query" {
        query = p.get("query", "");
        kind = step.get("kind");
        if kind == "provider_picker" or kind == "model_picker" {
            new_step = copy.deepcopy(step);
            new_step["query"] = query;
            return {"step": new_step};
        }
        return copy.deepcopy(current_state);
    }

    if action == "update_provider_filter" {
        provider_filter = p.get("providerFilter");
        if step.get("kind") == "model_picker" {
            new_step = copy.deepcopy(step);
            new_step["providerFilter"] = provider_filter;
            return {"step": new_step};
        }
        return copy.deepcopy(current_state);
    }

    if action == "cancel" {
        return {"step": {"kind": "idle"}};
    }

    if action == "reset" {
        return initial_auth_flow_state();
    }

    return copy.deepcopy(current_state);
}
