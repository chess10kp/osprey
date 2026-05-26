"""Gitignore matcher for project file discovery (Phase 2 leaf module)."""

from __future__ import annotations

from dataclasses import dataclass
from fnmatch import fnmatchcase
from pathlib import Path

DEFAULT_IGNORE_DIRS = [
    "node_modules",
    ".cache",
    "dist",
    "build",
    "out",
    ".next",
    ".nuxt",
    "__pycache__",
    ".pytest_cache",
    "target",
    "coverage",
    ".git",
    ".svn",
    ".hg",
    ".jac",
    ".jackal",
]


@dataclass(frozen=True)
class IgnoreRule:
    pattern: str
    negated: bool = False
    dir_only: bool = False
    anchored: bool = False
    has_slash: bool = False


def _normalize_rel(path: str) -> str:
    normalized = path.replace("\\", "/").strip()
    while normalized.startswith("./"):
        normalized = normalized[2:]
    if normalized.endswith("/"):
        normalized = normalized[:-1]
    return normalized.strip("/")


def _parse_gitignore(content: str) -> list[IgnoreRule]:
    rules: list[IgnoreRule] = []
    for raw in content.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue

        negated = line.startswith("!")
        if negated:
            line = line[1:].strip()
            if not line:
                continue

        anchored = line.startswith("/")
        if anchored:
            line = line[1:]

        dir_only = line.endswith("/")
        if dir_only:
            line = line[:-1]

        pattern = line.strip()
        if not pattern:
            continue

        rules.append(
            IgnoreRule(
                pattern=pattern,
                negated=negated,
                dir_only=dir_only,
                anchored=anchored,
                has_slash="/" in pattern,
            )
        )

    return rules


def _match_path_pattern(parts: list[str], rule: IgnoreRule) -> bool:
    pattern_parts = [p for p in rule.pattern.split("/") if p]
    if not pattern_parts:
        return False

    max_i = len(parts) - len(pattern_parts)
    if max_i < 0:
        return False

    starts = [0] if rule.anchored else range(0, max_i + 1)
    for i in starts:
        ok = True
        for j, pattern_part in enumerate(pattern_parts):
            if not fnmatchcase(parts[i + j], pattern_part):
                ok = False
                break
        if ok:
            return True

    return False


def _matches_rule(rel_path: str, is_dir: bool, rule: IgnoreRule) -> bool:
    rel = _normalize_rel(rel_path)
    if not rel:
        return False

    parts = rel.split("/")

    if rule.has_slash:
        return _match_path_pattern(parts, rule)

    if rule.dir_only:
        candidates = parts if is_dir else parts[:-1]
        return any(fnmatchcase(segment, rule.pattern) for segment in candidates)

    return any(fnmatchcase(segment, rule.pattern) for segment in parts)


class GitignoreMatcher:
    def __init__(self, default_dirs: list[str], rules: list[IgnoreRule]) -> None:
        self._default_dirs = [d.strip("/") for d in default_dirs if d.strip()]
        self._rules = rules

    def ignores(self, rel_path: str, is_dir: bool = False) -> bool:
        rel = _normalize_rel(rel_path)
        if not rel:
            return False

        parts = rel.split("/")
        ignored = any(part in self._default_dirs for part in parts[:-1] + ([parts[-1]] if is_dir else []))

        for rule in self._rules:
            if _matches_rule(rel, is_dir, rule):
                ignored = not rule.negated

        return ignored


def load_gitignore(cwd: str) -> GitignoreMatcher:
    path = Path(cwd) / ".gitignore"
    rules: list[IgnoreRule] = []
    if path.is_file():
        try:
            rules = _parse_gitignore(path.read_text(encoding="utf-8"))
        except OSError:
            rules = []
    return GitignoreMatcher(DEFAULT_IGNORE_DIRS, rules)
