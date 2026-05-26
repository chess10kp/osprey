"""System prompt loading — pick explicit/project/builtin prompt before skill catalog append."""

from __future__ import annotations

from pathlib import Path

_FALLBACK_SYSTEM = """You are Jackal, a Jac/Jaseci coding assistant.
Be concise, evidence-based, and correct. When unsure about Jac syntax, say so."""


def load_system_prompt_base(cwd: str, explicit: str | None = None) -> str:
    if explicit and explicit.strip():
        return explicit.strip()

    candidates = [
        Path(cwd) / "jackal" / "SYSTEM.md",
        Path(cwd) / "pi" / "SYSTEM.md",
    ]

    for path in candidates:
        try:
            if path.exists() and path.is_file():
                txt = path.read_text(encoding="utf-8").strip()
                if txt:
                    return txt
        except OSError:
            continue

    return _FALLBACK_SYSTEM
