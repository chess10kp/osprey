"""LLM compaction summary wrapping helper.

Ported from src/session/llm-compact.ts (wrapCompactionSummary).
The actual LLM call (summarizeForCompaction) stays in TS due to pi-agent-core deps.
"""

from __future__ import annotations


def wrap_compaction_summary(text: str) -> str:
    """Wrap a compaction summary in a conversation-summary XML tag.

    Parameters
    ----------
    text : str
        Raw summary text from the LLM.

    Returns
    -------
    str
        Wrapped summary with XML tags and continuation instruction.
        Returns empty string if *text* is blank.
    """
    trimmed = text.strip()
    if not trimmed:
        return ""
    return "\n".join([
        "<conversation-summary>",
        trimmed,
        "</conversation-summary>",
        "",
        "(The above is an automated summary of earlier conversation. Continue from the most recent message.)",
    ])
