"""Project file listing + token estimates (Phase 2 leaf module)."""

from __future__ import annotations

import os
from pathlib import Path

from _gitignore_toolchain import load_gitignore

CHARS_PER_TOKEN = 4
TOKEN_WARN_THRESHOLD = 10_000


def list_project_files(
    cwd: str,
    max_depth: int = 6,
    max_files: int = 3000,
    respect_gitignore: bool = True,
) -> list[str]:
    matcher = load_gitignore(cwd) if respect_gitignore else None
    out: list[str] = []

    def walk(dir_path: str, depth: int, rel_prefix: str) -> None:
        if depth > max_depth or len(out) >= max_files:
            return

        try:
            entries = sorted(os.scandir(dir_path), key=lambda e: e.name)
        except OSError:
            return

        for entry in entries:
            name = entry.name
            if name.startswith(".") and name != ".env.example":
                continue

            rel = f"{rel_prefix}/{name}" if rel_prefix else name
            rel_posix = rel.replace("\\", "/")

            try:
                is_dir = entry.is_dir(follow_symlinks=False)
            except OSError:
                continue

            if matcher and matcher.ignores(rel_posix, is_dir=is_dir):
                continue

            if is_dir:
                walk(entry.path, depth + 1, rel_posix)
            else:
                try:
                    if entry.is_file(follow_symlinks=False):
                        out.append(rel_posix)
                except OSError:
                    continue

            if len(out) >= max_files:
                break

    walk(cwd, 0, "")
    return out


def estimate_tokens_from_chars(chars: int) -> int:
    return (max(chars, 0) + CHARS_PER_TOKEN - 1) // CHARS_PER_TOKEN


def format_token_estimate(chars: int) -> str:
    tokens = estimate_tokens_from_chars(chars)
    if tokens >= TOKEN_WARN_THRESHOLD:
        return f"~{tokens:,} tokens (large selection)"
    return f"~{tokens:,} tokens"


def estimate_selection_chars(cwd: str, paths: list[str]) -> dict:
    chars = 0

    for p in paths:
        abs_path = Path(p)
        if not abs_path.is_absolute():
            abs_path = Path(cwd) / p
        try:
            content = abs_path.read_text(encoding="utf-8")
            chars += len(content)
        except OSError:
            chars += 100

    tokens = estimate_tokens_from_chars(chars)
    return {
        "chars": chars,
        "tokens": tokens,
        "warn": tokens >= TOKEN_WARN_THRESHOLD,
    }
