"""Checkpoint store — conversation + git-tracked file snapshots under .jackal/checkpoints/."""

from __future__ import annotations

import json
import os
import subprocess
import uuid
from datetime import datetime, timezone
from pathlib import Path

MAX_CHECKPOINT_FILES = 500
DESCRIPTION_LENGTH = 80


def checkpoints_dir(cwd: str) -> str:
    return os.path.join(cwd, ".jackal", "checkpoints")


def validate_checkpoint_name(name: str) -> dict:
    if not name or not name.strip():
        return {"valid": False, "error": "Checkpoint name cannot be empty"}
    if len(name) > 100:
        return {"valid": False, "error": "Checkpoint name must be 100 characters or less"}
    if any(c in name for c in '<>:"/\\|?*'):
        return {"valid": False, "error": "Checkpoint name contains invalid characters"}
    if name.startswith(".") or name.endswith(".") or name.startswith(" ") or name.endswith(" "):
        return {"valid": False, "error": "Checkpoint name cannot start or end with a dot or space"}
    return {"valid": True}


def _generate_checkpoint_name() -> str:
    ts = datetime.now(timezone.utc).isoformat().replace(":", "-").replace(".", "-").replace("T", "-")
    return f"checkpoint-{ts.split('-fallback')[0]}"


def _checkpoint_path(cwd: str, name: str) -> str:
    return os.path.join(checkpoints_dir(cwd), name)


def _generate_description(messages: list[dict]) -> str:
    for msg in messages:
        role = msg.get("role")
        content = msg.get("content")
        if role == "user" and isinstance(content, str) and content.strip():
            text = content.strip()
            return text[:DESCRIPTION_LENGTH] + "..." if len(text) > DESCRIPTION_LENGTH else text
    return "Empty conversation"


def _git_commit_hash(cwd: str) -> str | None:
    try:
        result = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=cwd, capture_output=True, text=True, timeout=5,
        )
        return result.stdout.strip() if result.returncode == 0 else None
    except Exception:
        return None


def get_modified_files(cwd: str) -> list[str]:
    try:
        modified = subprocess.run(
            ["git", "diff", "--name-only", "HEAD"],
            cwd=cwd, capture_output=True, text=True, timeout=10,
        )
        untracked = subprocess.run(
            ["git", "ls-files", "--others", "--exclude-standard"],
            cwd=cwd, capture_output=True, text=True, timeout=10,
        )
        mod_files = [f for f in modified.stdout.strip().split("\n") if f] if modified.returncode == 0 else []
        untracked_files = [f for f in untracked.stdout.strip().split("\n") if f] if untracked.returncode == 0 else []
        all_files = list(dict.fromkeys(mod_files + untracked_files))
        return all_files[:MAX_CHECKPOINT_FILES]
    except Exception:
        return []


def _capture_files(cwd: str, file_paths: list[str]) -> dict[str, str]:
    snapshots: dict[str, str] = {}
    for fp in file_paths:
        try:
            abs_path = os.path.resolve(cwd, fp)
            content = Path(abs_path).read_text(encoding="utf-8")
            rel = os.path.relpath(abs_path, cwd).replace("\\", "/")
            snapshots[rel] = content
        except Exception:
            pass
    return snapshots


def _dir_size(dir_path: str) -> int:
    total = 0
    try:
        for entry in os.scandir(dir_path):
            if entry.is_dir():
                total += _dir_size(entry.path)
            elif entry.is_file():
                total += entry.stat().st_size
    except OSError:
        pass
    return total


def create_checkpoint(
    cwd: str,
    messages: list[dict],
    provider: str,
    model: str,
    name: str | None = None,
    modified_files: list[str] | None = None,
) -> dict:
    os.makedirs(checkpoints_dir(cwd), exist_ok=True)

    checkpoint_name = (name or "").strip() or _generate_checkpoint_name()
    validation = validate_checkpoint_name(checkpoint_name)
    if not validation["valid"]:
        raise ValueError(validation.get("error", "Invalid checkpoint name"))

    dir_path = _checkpoint_path(cwd, checkpoint_name)
    if os.path.exists(dir_path):
        raise ValueError(f"Checkpoint '{checkpoint_name}' already exists")

    files_to_snapshot = modified_files if modified_files is not None else get_modified_files(cwd)
    file_snapshots = _capture_files(cwd, files_to_snapshot)

    now = datetime.now(timezone.utc).isoformat()
    metadata = {
        "name": checkpoint_name,
        "timestamp": now,
        "messageCount": len(messages),
        "filesChanged": list(file_snapshots.keys()),
        "provider": {"name": provider, "model": model},
        "description": _generate_description(messages),
        "gitCommitHash": _git_commit_hash(cwd),
    }

    conversation = {"messages": messages}

    os.makedirs(dir_path, exist_ok=True)
    Path(os.path.join(dir_path, "metadata.json")).write_text(
        json.dumps(metadata, indent=2) + "\n", encoding="utf-8"
    )
    Path(os.path.join(dir_path, "conversation.json")).write_text(
        json.dumps(conversation, indent=2) + "\n", encoding="utf-8"
    )

    if file_snapshots:
        files_dir = os.path.join(dir_path, "files")
        os.makedirs(files_dir, exist_ok=True)
        for rel_path, content in file_snapshots.items():
            fp = os.path.join(files_dir, rel_path)
            os.makedirs(os.path.dirname(fp), exist_ok=True)
            Path(fp).write_text(content, encoding="utf-8")

    return metadata


def load_checkpoint(cwd: str, name: str) -> dict:
    dir_path = _checkpoint_path(cwd, name)
    if not os.path.exists(dir_path):
        raise ValueError(f"Checkpoint '{name}' does not exist")

    metadata = json.loads(Path(os.path.join(dir_path, "metadata.json")).read_text(encoding="utf-8"))
    conversation = json.loads(Path(os.path.join(dir_path, "conversation.json")).read_text(encoding="utf-8"))

    file_snapshots: dict[str, str] = {}
    files_dir = os.path.join(dir_path, "files")
    if os.path.exists(files_dir):
        for rel_path in metadata.get("filesChanged", []):
            try:
                content = Path(os.path.join(files_dir, rel_path)).read_text(encoding="utf-8")
                file_snapshots[rel_path] = content
            except Exception:
                pass

    return {
        "metadata": metadata,
        "conversation": conversation,
        "fileSnapshots": file_snapshots,
    }


def list_checkpoints(cwd: str) -> list[dict]:
    cp_dir = checkpoints_dir(cwd)
    os.makedirs(cp_dir, exist_ok=True)

    items: list[dict] = []
    try:
        entries = os.listdir(cp_dir)
    except OSError:
        return []

    for entry in entries:
        dir_path = os.path.join(cp_dir, entry)
        if not os.path.isdir(dir_path):
            continue
        meta_path = os.path.join(dir_path, "metadata.json")
        if not os.path.exists(meta_path):
            continue
        try:
            metadata = json.loads(Path(meta_path).read_text(encoding="utf-8"))
            items.append({
                "name": entry,
                "metadata": metadata,
                "sizeBytes": _dir_size(dir_path),
            })
        except Exception:
            pass

    items.sort(key=lambda x: x["metadata"].get("timestamp", ""), reverse=True)
    return items


def delete_checkpoint(cwd: str, name: str) -> None:
    dir_path = _checkpoint_path(cwd, name)
    if not os.path.exists(dir_path):
        raise ValueError(f"Checkpoint '{name}' does not exist")
    import shutil
    shutil.rmtree(dir_path)


def restore_checkpoint_files(cwd: str, snapshots: dict[str, str]) -> None:
    errors: list[str] = []
    for rel_path, content in snapshots.items():
        try:
            abs_path = os.path.resolve(cwd, rel_path)
            os.makedirs(os.path.dirname(abs_path), exist_ok=True)
            Path(abs_path).write_text(content, encoding="utf-8")
        except Exception as e:
            errors.append(f"Failed to restore {rel_path}: {e}")

    if errors:
        raise RuntimeError("Failed to restore some files:\n" + "\n".join(errors))


def format_relative_time(timestamp: str) -> str:
    now = datetime.now(timezone.utc).timestamp()
    t = datetime.fromisoformat(timestamp).timestamp()
    diff_minutes = int((now - t) / 60)
    diff_hours = diff_minutes // 60
    diff_days = diff_hours // 24

    if diff_minutes < 1:
        return "just now"
    if diff_minutes < 60:
        return f"{diff_minutes} min{'s' if diff_minutes != 1 else ''} ago"
    if diff_hours < 24:
        return f"{diff_hours} hr{'s' if diff_hours != 1 else ''} ago"
    if diff_days < 7:
        return f"{diff_days} day{'s' if diff_days != 1 else ''} ago"
    return datetime.fromisoformat(timestamp).strftime("%Y-%m-%d")


def format_checkpoint_overlay_row(item: dict) -> str:
    m = item["metadata"]
    when = format_relative_time(m["timestamp"])
    size_kb = f"{round(item.get('sizeBytes', 0) / 1024)}KB" if item.get("sizeBytes") else "?"
    return f"{m['name']} — {m['messageCount']} msgs, {len(m['filesChanged'])} files — {when} ({size_kb})"


def format_checkpoint_list(items: list[dict]) -> str:
    if not items:
        return "No checkpoints. Use /checkpoint create [name]."

    lines = []
    for item in items:
        m = item["metadata"]
        when = datetime.fromisoformat(m["timestamp"]).strftime("%Y-%m-%d %H:%M")
        size_kb = f"{round(item.get('sizeBytes', 0) / 1024)}KB" if item.get("sizeBytes") else "?"
        lines.append(f"- {m['name']} ({when}, {m['messageCount']} msgs, {len(m['filesChanged'])} files, {size_kb})")

    return "Checkpoints:\n" + "\n".join(lines)
