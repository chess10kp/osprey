"""Store types, constants, and pure bridge helpers for the agent snapshot.

Ported from src/core/store.ts and src/core/bridge.ts.

This module contains ONLY pure functions and constants — no reactive
subscriptions, no class instances, no event listeners. The AgentStore
class itself (with its listener / mutation API) stays in TypeScript
because it is deeply coupled to React's useSyncExternalStore.
"""

from __future__ import annotations

import json
from typing import Any

# Import truncation from the existing toolchain module.
# At runtime this file lives in lib/jac/core/ and lib/jac/agent/ is on sys.path
# via toolchain_stdio.py.  For direct import we add a relative fallback.
try:
    from _tool_output_limit_toolchain import (  # type: ignore[import-not-found]
        truncate_tool_output as _truncate_tool_output,
        truncate_tool_payload as _truncate_tool_payload,
    )
except ImportError:
    import os
    import sys

    _agent = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", "agent"))
    if _agent not in sys.path:
        sys.path.insert(0, _agent)
    from _tool_output_limit_toolchain import (
        truncate_tool_output as _truncate_tool_output,
        truncate_tool_payload as _truncate_tool_payload,
    )

# ── Constants ────────────────────────────────────────────────────────────────

AGENT_PHASES: list[str] = ["booting", "ready", "streaming", "compacting", "retrying", "error"]
"""All valid AgentPhase values."""

MAX_TOOL_EXECUTIONS: int = 40
"""Keep only the most recent tool executions in the store."""

STREAM_EMIT_MS: int = 32
"""Throttle streaming UI updates to reduce re-render churn (~30 fps)."""

# ── Initial snapshot ─────────────────────────────────────────────────────────

INITIAL_SNAPSHOT: dict[str, Any] = {
    "phase": "booting",
    "mode": "normal",
    "pendingApproval": None,
    "pendingSubagentApproval": None,
    "model": "",
    "provider": "",
    "sessionId": "",
    "sessionName": "",
    "mcpConnected": False,
    "mcpConnecting": False,
    "mcpServer": "",
    "mcpToolCount": 0,
    "mcpError": None,
    "messages": [],
    "transcript": [],
    "transcriptEpoch": 0,
    "streamingText": None,
    "liveToolCallId": None,
    "toolExecutions": {},
    "tokens": None,
    "cost": None,
    "error": None,
    "queuedMessages": [],
}
"""Default AgentSnapshot dict (mirrors TS INITIAL_SNAPSHOT)."""

# ── Dict shapes (documented, not enforced) ────────────────────────────────────
#
# ToolExecution:
#   toolCallId: str
#   toolName: str
#   status: "running" | "done" | "error"
#   input?: dict
#   summary?: str
#   result?: str
#   durationMs?: int
#
# ToolTranscriptEntry:
#   kind: "tool"
#   toolCallId: str
#   toolName: str
#   status: "running" | "done" | "error"
#   input?: dict
#   summary?: str
#   result?: str
#   durationMs?: int
#
# TranscriptEntry (union):
#   { kind: "user" | "assistant" | "system", text: str }
#   | ToolTranscriptEntry
#
# AgentMessage (store format):
#   role: "user" | "assistant" | "system"
#   text: str


# ── store.ts pure helpers ────────────────────────────────────────────────────

def agent_messages_to_transcript(
    messages: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    """Map store-format AgentMessage dicts to TranscriptEntry dicts.

    Each message has ``role`` (user|assistant|system) and ``text``.
    The output entries have ``kind`` set to the role and ``text`` copied.
    """
    return [{"kind": m["role"], "text": m["text"]} for m in messages]


# ── bridge.ts pure helpers ───────────────────────────────────────────────────

def tool_result_display_text(value: Any) -> str | None:
    """Extract display text from a tool result value.

    Returns a string for display, or None when the value is not
    representable as plain text.
    """
    if value is None or value is undefined_sentinel:
        return None
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        if "error" in value:
            return str(value.get("error") or "Tool failed")
        if "content" in value and isinstance(value.get("content"), list):
            parts: list[str] = []
            for part in value["content"]:
                if isinstance(part, dict) and part.get("type") == "text" and isinstance(part.get("text"), str):
                    parts.append(part["text"])
            if parts:
                return "\n".join(parts)
    return None


def format_tool_payload(value: Any) -> str | None:
    """Format a tool result for store display (truncated)."""
    display = tool_result_display_text(value)
    if display is not None:
        return _truncate_tool_payload(display)
    return _truncate_tool_payload(value)


def tool_result_status(value: Any, is_error: Any = None) -> str:
    """Return 'done' or 'error' based on the tool result and error flag."""
    if is_error is True:
        return "error"
    if isinstance(value, dict) and "error" in value:
        return "error"
    return "done"


def agent_message_to_store(message: dict[str, Any]) -> dict[str, str] | None:
    """Convert a pi-agent-core message dict to a store message dict.

    Returns ``{"role": ..., "text": ...}`` or None if the role is
    not recognised.
    """
    role = message.get("role")
    if role not in ("user", "assistant", "system"):
        return None

    content = message.get("content")
    text = _content_to_text(content)
    return {"role": role, "text": text}


def agent_messages_to_store(messages: list[Any]) -> list[dict[str, str]]:
    """Convert a list of pi-agent-core message dicts to store message dicts."""
    out: list[dict[str, str]] = []
    for msg in messages:
        if not isinstance(msg, dict):
            continue
        converted = agent_message_to_store(msg)
        if converted is not None:
            out.append(converted)
    return out


def build_seed_data(
    mode: str,
    provider: str,
    model: str,
    session_id: str,
    session_name: str,
    messages: list[Any] | None = None,
) -> dict[str, Any]:
    """Build the initial store seed data dict (for ``seedStoreFromSession``).

    This is the pure-data counterpart: it returns a dict that the TS
    adapter can spread into the store on boot.
    """
    seed: dict[str, Any] = {
        "mode": mode,
        "provider": provider,
        "model": model,
        "sessionId": session_id,
        "sessionName": session_name,
    }
    if messages:
        store_msgs = agent_messages_to_store(messages)
        if store_msgs:
            seed["messages"] = store_msgs
            seed["transcript"] = agent_messages_to_transcript(store_msgs)
    return seed


# ── Internal helpers ─────────────────────────────────────────────────────────

class _Undefined:
    """Sentinel for JavaScript ``undefined`` (distinct from Python ``None``)."""

    _instance: _Undefined | None = None

    def __new__(cls) -> _Undefined:
        if cls._instance is None:
            cls._instance = super().__new__(cls)
        return cls._instance

    def __repr__(self) -> str:
        return "undefined"

    def __bool__(self) -> bool:
        return False


undefined_sentinel = _Undefined()


def _content_to_text(content: Any) -> str:
    """Extract text from pi-agent-core content (string, array, or object)."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts: list[str] = []
        for part in content:
            if isinstance(part, str):
                parts.append(part)
            elif isinstance(part, dict) and "text" in part:
                parts.append(str(part.get("text") or ""))
            else:
                parts.append(json.dumps(part))
        return "\n".join(parts)
    if content is not None:
        try:
            return json.dumps(content)
        except Exception:
            return str(content)
    return ""
