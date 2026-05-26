"""Agent busy detection — pure snapshot predicate.

Ported from src/core/agent-busy.ts.
"""

from __future__ import annotations

from typing import Any


def is_agent_busy(snap: dict[str, Any]) -> bool:
    """Return True when the agent loop, compaction, retry, or a tool is in flight.

    Parameters
    ----------
    snap : dict
        AgentSnapshot dict with keys: phase, liveToolCallId, toolExecutions.

    Returns
    -------
    bool
    """
    phase = snap.get("phase")
    if phase in ("streaming", "compacting", "retrying"):
        return True
    if snap.get("liveToolCallId"):
        return True
    tool_executions = snap.get("toolExecutions", {})
    for t in tool_executions.values():
        if isinstance(t, dict) and t.get("status") == "running":
            return True
    return False
