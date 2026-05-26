"""Auto-compact — automatic context compaction triggered at context % threshold."""

from __future__ import annotations

from typing import Literal, TypedDict

CompactStrategy = Literal["llm", "mechanical"]


class AutoCompactConfig(TypedDict, total=False):
    enabled: bool
    thresholdPercent: int
    keepTail: int
    notify: bool
    strategy: CompactStrategy


DEFAULT_AUTO_COMPACT: AutoCompactConfig = {
    "enabled": True,
    "thresholdPercent": 80,
    "keepTail": 12,
    "notify": True,
    "strategy": "llm",
}


class AutoCompactResult(TypedDict, total=False):
    triggered: bool
    reason: str
    dropped: int
    messageCountBefore: int
    messageCountAfter: int


def resolve_auto_compact_config(raw: dict) -> AutoCompactConfig:
    """Resolve auto-compact config from raw .jackal settings.

    Args:
        raw: Dict with optional keys 'autoCompact' (bool or partial dict)
             and 'compactStrategy' ('llm' or 'mechanical').

    Returns:
        Fully resolved AutoCompactConfig dict.
    """
    auto_compact = raw.get("autoCompact")
    compact_strategy = raw.get("compactStrategy")

    if auto_compact is False:
        merged = {**DEFAULT_AUTO_COMPACT, "enabled": False}
    elif auto_compact is True:
        merged = {**DEFAULT_AUTO_COMPACT, "enabled": True}
    elif isinstance(auto_compact, dict):
        merged = {**DEFAULT_AUTO_COMPACT, **auto_compact}
    else:
        merged = {**DEFAULT_AUTO_COMPACT}

    if compact_strategy in ("llm", "mechanical"):
        merged["strategy"] = compact_strategy

    return merged


def _extract_message_text(message: dict) -> str:
    """Extract display text from a message dict with role and content fields."""
    content = message.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts: list[str] = []
        for part in content:
            if isinstance(part, str):
                parts.append(part)
            elif isinstance(part, dict):
                if "text" in part:
                    parts.append(str(part.get("text", "")))
                elif part.get("type") == "toolCall":
                    parts.append(f"[tool call: {part.get('name', 'unknown')}]")
        return " | ".join(p for p in parts if p)
    if content is not None:
        return str(content)
    return ""


def build_mechanical_summary(messages: list[dict]) -> str:
    """Build a mechanical summary of dropped messages.

    Used when no LLM summary is available (headless / no model).

    Args:
        messages: List of message dicts with 'role' and 'content' fields.

    Returns:
        XML-wrapped summary string.
    """
    lines = [
        "<context-summary>",
        "Earlier conversation context (auto-compacted for space):",
        "",
    ]

    for msg in messages:
        role = msg.get("role", "unknown")
        text = _extract_message_text(msg)
        truncated = text[:297] + "..." if len(text) > 300 else text
        lines.append(f"[{role}] {truncated}")

    lines.append("</context-summary>")
    return "\n".join(lines)


def should_auto_compact(usage_percent: float, config: AutoCompactConfig) -> bool:
    """Check if auto-compact should trigger based on context usage percent.

    Args:
        usage_percent: Current context usage as a percentage (0-100).
        config: Resolved auto-compact config dict.

    Returns:
        True if compaction should be triggered.
    """
    if not config.get("enabled", True):
        return False
    return usage_percent >= config.get("thresholdPercent", 80)


def build_llm_summary_prompt(messages: list[dict]) -> str:
    """Build the compaction prompt for LLM-based summarization.

    The agent uses this to ask the model to summarize older context.

    Args:
        messages: List of message dicts with 'role' and 'content' fields.

    Returns:
        Prompt string for LLM summarization.
    """
    previews: list[str] = []
    for msg in messages:
        role = msg.get("role", "unknown")
        text = _extract_message_text(msg)
        truncated = text[:197] + "..." if len(text) > 200 else text
        previews.append(f"[{role}] {truncated}")

    return "\n".join([
        "Summarize the following conversation context in 200 words or less.",
        "Preserve key facts: file paths, function/class names, error messages, decisions made, and any code patterns discussed.",
        "Do NOT include pleasantries or filler — only technical substance.",
        "",
        *previews,
    ])
