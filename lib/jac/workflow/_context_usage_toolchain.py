"""Context usage estimation — token counting for session context windows."""

from __future__ import annotations

CHARS_PER_TOKEN = 4
DEFAULT_CONTEXT_MAX = 128_000


def estimate_tokens(text: str) -> int:
    if not text:
        return 0
    return (len(text) + CHARS_PER_TOKEN - 1) // CHARS_PER_TOKEN


def message_to_text(message: dict) -> str:
    content = message.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for part in content:
            if isinstance(part, str):
                parts.append(part)
            elif isinstance(part, dict):
                if part.get("type") == "text" and part.get("text"):
                    parts.append(part["text"])
                else:
                    import json
                    parts.append(json.dumps(part))
            else:
                parts.append(str(part))
        return "\n".join(parts)
    if content is not None:
        import json
        return json.dumps(content)
    return ""


def estimate_messages_tokens(messages: list[dict]) -> int:
    total = 0
    for msg in messages:
        total += estimate_tokens(message_to_text(msg))
        total += 4  # role/overhead fudge
    return total


def get_context_max(context_window: int | None = None, override: int | None = None) -> int:
    if isinstance(override, int) and override > 0:
        return override
    if isinstance(context_window, int) and context_window > 0:
        return context_window
    return DEFAULT_CONTEXT_MAX


def compute_context_usage(
    messages: list[dict],
    system_prompt: str = "",
    context_window: int | None = None,
    context_max_override: int | None = None,
) -> dict:
    system_prompt_tokens = estimate_tokens(system_prompt)
    message_tokens = estimate_messages_tokens(messages)
    used = system_prompt_tokens + message_tokens
    max_tokens = get_context_max(context_window, context_max_override)
    percent = min(100, round((used / max_tokens) * 100)) if max_tokens > 0 else 0
    return {
        "used": used,
        "max": max_tokens,
        "percent": percent,
        "systemPromptTokens": system_prompt_tokens,
        "messageTokens": message_tokens,
    }


def format_usage_line(usage: dict) -> str:
    used = usage["used"]
    max_val = usage["max"]
    pct = usage["percent"]
    return f"Context: {used:,} / {max_val:,} tokens ({pct}%)"
