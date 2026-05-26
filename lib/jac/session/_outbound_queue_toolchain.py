"""Outbound message queue — pure data structure.

Ported from src/session/outbound-queue.ts.
"""

from __future__ import annotations

from typing import Any


class OutboundMessageQueue:
    """FIFO queue for outbound user messages waiting for agent idle."""

    def __init__(self) -> None:
        self._items: list[str] = []

    @property
    def length(self) -> int:
        return len(self._items)

    def peek(self) -> list[str]:
        """Shallow copy for UI display."""
        return list(self._items)

    def enqueue(self, text: str) -> None:
        """Add a trimmed message to the queue. Empty strings are ignored."""
        trimmed = text.strip()
        if not trimmed:
            return
        self._items.append(trimmed)

    def dequeue(self) -> str | None:
        """Remove and return the next message, or None if empty."""
        return self._items.pop(0) if self._items else None

    def clear(self) -> None:
        """Remove all queued messages."""
        self._items.clear()

    def to_dict(self) -> dict[str, Any]:
        """Serialize for bridge transport."""
        return {"items": list(self._items), "length": len(self._items)}

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "OutboundMessageQueue":
        """Deserialize from bridge transport."""
        q = cls()
        q._items = [str(i) for i in data.get("items", [])]
        return q
