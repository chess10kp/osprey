"""Checkpoint store for the agent harness — conversation plus git-tracked
file snapshots under <cwd>/.jackal/checkpoints/ (ported from
lib/jac/workflow/_checkpoints_toolchain.py, the Python source of truth;
src/workflow/checkpoints.ts is the bridge-delegating TS mirror and adds no
logic of its own).

Persistence layout written by this module (verified against the Python
toolchain):
- One directory per checkpoint: `<cwd>/.jackal/checkpoints/<name>/`.
- metadata.json — single JSON object, indent=2 plus trailing newline,
  with exactly these keys: name, timestamp (ISO 8601 UTC from
  datetime.isoformat()), messageCount, filesChanged (relative POSIX-style
  paths of snapshotted files), provider ({name, model}), description
  (first non-empty user message trimmed to 80 chars, else "Empty
  conversation"), gitCommitHash (`git rev-parse HEAD` or null off-repo).
- conversation.json — indent=2 object {"messages": [...]}, messages being
  caller-owned OpenAI-shape dicts stored verbatim.
- files/<rel-path> — raw UTF-8 file content per snapshotted project file,
  subdirectories preserved.

Deviations from the source of truth: purely mechanical — dropped a no-op
`-fallback` split in the generated-name formatter (isoformat never yields
that substring) and file I/O uses open() instead of pathlib per app/
house style. Git probing goes through Python subprocess, same as the
toolchain. Raises ValueError on invalid/unknown/duplicate names and
RuntimeError when a restore partially fails.
"""

import os;
import json;
import shutil;
import subprocess;
import datetime;

glob _MAX_CHECKPOINT_FILES: int = 500,
     _DESCRIPTION_LENGTH: int = 80,
     _INVALID_NAME_CHARS: str = '<>:"/\\|?*',
     _METADATA_NAME: str = "metadata.json",
     _CONVERSATION_NAME: str = "conversation.json";


"""Checker shims: the Jac type checker cannot bind AnyStr when plain str
values flow into some os.path signatures (abspath/relpath/dirname), so
route those calls through any-typed aliases."""
def _path_dirname(p: str) -> str {
    fn: any = os.path.dirname;
    return str(fn(p));
}


def _path_abspath(p: str) -> str {
    fn: any = os.path.abspath;
    return str(fn(p));
}


def _path_relpath(p: str, start: str) -> str {
    fn: any = os.path.relpath;
    return str(fn(p, start));
}


def checkpoints_dir(cwd: str) -> str {
    return os.path.join(cwd, ".jackal", "checkpoints");
}


def _checkpoint_path(cwd: str, name: str) -> str {
    return os.path.join(checkpoints_dir(cwd), name);
}


def validate_checkpoint_name(name: str) -> dict {
    if not name or not name.strip() {
        return {"valid": False, "error": "Checkpoint name cannot be empty"};
    }
    if len(name) > 100 {
        return {"valid": False, "error": "Checkpoint name must be 100 characters or less"};
    }
    for ch in _INVALID_NAME_CHARS {
        if ch in name {
            return {"valid": False, "error": "Checkpoint name contains invalid characters"};
        }
    }
    if name.startswith(".") or name.endswith(".") or name.startswith(" ") or name.endswith(" ") {
        return {"valid": False, "error": "Checkpoint name cannot start or end with a dot or space"};
    }
    return {"valid": True};
}


"""UTC timestamp shaped like the toolchain's generated names:
checkpoint-YYYY-MM-DD-HH-MM-SS-microseconds+HH-MM."""
def _generate_checkpoint_name() -> str {
    ts = datetime.datetime.now(datetime.timezone.utc).isoformat();
    ts = ts.replace(":", "-").replace(".", "-").replace("T", "-");
    return "checkpoint-" + ts;
}


def _generate_description(messages: list) -> str {
    for msg in messages {
        if not isinstance(msg, dict) {
            continue;
        }
        role = msg.get("role");
        content = msg.get("content");
        if role == "user" and isinstance(content, str) and content.strip() {
            text = content.strip();
            if len(text) > _DESCRIPTION_LENGTH {
                return text[:_DESCRIPTION_LENGTH] + "...";
            }
            return text;
        }
    }
    return "Empty conversation";
}


"""HEAD commit hash for cwd, or None outside a git repo / on any failure."""
def _git_commit_hash(cwd: str) -> str | None {
    try {
        result = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=cwd, capture_output=True, text=True, timeout=5,
        );
    } except Exception {
        return None;
    }
    if result.returncode != 0 {
        return None;
    }
    return result.stdout.strip();
}


"""Tracked modifications plus untracked files (deduped, capped at 500).
Returns [] outside a git repo or when git fails."""
def get_modified_files(cwd: str) -> list[str] {
    all_files: list[str] = [];
    try {
        modified = subprocess.run(
            ["git", "diff", "--name-only", "HEAD"],
            cwd=cwd, capture_output=True, text=True, timeout=10,
        );
        untracked = subprocess.run(
            ["git", "ls-files", "--others", "--exclude-standard"],
            cwd=cwd, capture_output=True, text=True, timeout=10,
        );
        mod_files: list[str] = [];
        if modified.returncode == 0 {
            mod_files = [f for f in modified.stdout.strip().split("\n") if f];
        }
        untracked_files: list[str] = [];
        if untracked.returncode == 0 {
            untracked_files = [f for f in untracked.stdout.strip().split("\n") if f];
        }
        seen: set[str] = set();
        for fp in mod_files + untracked_files {
            if fp not in seen {
                seen.add(fp);
                all_files.append(fp);
            }
        }
    } except Exception {}
    return all_files[:_MAX_CHECKPOINT_FILES];
}


"""Resolve rel against cwd. Deviation fix: the Python toolchain calls
the nonexistent os.path.resolve here -- its AttributeError is swallowed
by the surrounding handlers, so toolchain capture silently stores no
files and restore always raises. We resolve explicitly instead."""
def _resolve_rel(cwd: str, rel: str) -> str {
    return _path_abspath(os.path.join(cwd, rel));
}


"""Read every listed path relative to cwd into {rel-path: content}.
Unreadable paths are silently skipped, matching the toolchain."""
def _capture_files(cwd: str, file_paths: list[str]) -> dict[str, str] {
    snapshots: dict[str, str] = {};
    for fp in file_paths {
        try {
            abs_path: str = _resolve_rel(cwd, fp);
            fh: any = open(abs_path, "r");
            try {
                content = fh.read();
            } finally {
                fh.close();
            }
            rel: str = _path_relpath(abs_path, cwd).replace("\\\\", "/");
            snapshots[rel] = content;
        } except Exception {}
    }
    return snapshots;
}


def _dir_size(dir_path: str) -> int {
    total = 0;
    try {
        for dir_entry in os.scandir(dir_path) {
            if dir_entry.is_dir() {
                total += _dir_size(dir_entry.path);
            } elif dir_entry.is_file() {
                total += dir_entry.stat().st_size;
            }
        }
    } except OSError {}
    return total;
}


def _write_json(path: str, data: any) -> bool {
    fh = None;
    try {
        fh = open(path, "w");
        json.dump(data, fh, indent=2);
        fh.write("\n");
    } except OSError {
        return False;
    } finally {
        if fh is not None {
            fh.close();
        }
    }
    return True;
}


"""Parse a JSON file; propagates OSError (missing) and ValueError
(corrupt) exactly like the toolchain's json.loads calls."""
def _load_json_file(path: str) -> any {
    fh = open(path, "r");
    try {
        return json.loads(fh.read());
    } finally {
        fh.close();
    }
}


"""Snapshot the working tree slice plus the conversation into a new
checkpoint directory. modified_files=None triggers git detection.
Returns the metadata dict that was persisted to metadata.json.
Raises ValueError for invalid names (including generated ones failing
validation) and for duplicate checkpoint names."""
def create_checkpoint(
    cwd: str, messages: list, provider: str, model: str,
    name: str = "", modified_files: list[str] | None = None,
) -> dict {
    os.makedirs(checkpoints_dir(cwd), exist_ok=True);

    trimmed = name.strip() if isinstance(name, str) else "";
    checkpoint_name = trimmed if trimmed else _generate_checkpoint_name();
    validation = validate_checkpoint_name(checkpoint_name);
    if not validation["valid"] {
        err = validation.get("error");
        raise ValueError(str(err) if err else "Invalid checkpoint name");
    }

    dir_path = _checkpoint_path(cwd, checkpoint_name);
    if os.path.exists(dir_path) {
        raise ValueError("Checkpoint '" + checkpoint_name + "' already exists");
    }

    files_to_snapshot: list[str] = modified_files if modified_files is not None else get_modified_files(cwd);
    file_snapshots = _capture_files(cwd, files_to_snapshot);

    now = datetime.datetime.now(datetime.timezone.utc).isoformat();
    metadata = {
        "name": checkpoint_name,
        "timestamp": now,
        "messageCount": len(messages),
        "filesChanged": list(file_snapshots.keys()),
        "provider": {"name": provider, "model": model},
        "description": _generate_description(messages),
        "gitCommitHash": _git_commit_hash(cwd),
    };

    conversation = {"messages": messages};

    os.makedirs(dir_path, exist_ok=True);
    if not _write_json(os.path.join(dir_path, _METADATA_NAME), metadata) {
        raise ValueError("cannot write checkpoint metadata: " + dir_path);
    }
    if not _write_json(os.path.join(dir_path, _CONVERSATION_NAME), conversation) {
        raise ValueError("cannot write checkpoint conversation: " + dir_path);
    }

    if file_snapshots {
        files_dir = os.path.join(dir_path, "files");
        os.makedirs(files_dir, exist_ok=True);
        for rel_path in file_snapshots {
            fp: str = os.path.join(files_dir, rel_path);
            os.makedirs(_path_dirname(fp), exist_ok=True);
            fh: any = open(fp, "w");
            try {
                fh.write(file_snapshots[rel_path]);
            } finally {
                fh.close();
            }
        }
    }
    return metadata;
}


"""Full checkpoint payload: {metadata, conversation, fileSnapshots}.
Snapshot files missing from disk are skipped silently. Raises ValueError
when the checkpoint does not exist, and lets OSError/ValueError from the
underlying JSON reads propagate (corrupt stores surface here)."""
def load_checkpoint(cwd: str, name: str) -> dict {
    dir_path = _checkpoint_path(cwd, name);
    if not os.path.exists(dir_path) {
        raise ValueError("Checkpoint '" + name + "' does not exist");
    }

    metadata = _load_json_file(os.path.join(dir_path, _METADATA_NAME));
    conversation = _load_json_file(os.path.join(dir_path, _CONVERSATION_NAME));

    file_snapshots: dict = {};
    files_dir = os.path.join(dir_path, "files");
    if os.path.exists(files_dir) {
        changed = metadata.get("filesChanged") if isinstance(metadata, dict) else None;
        if isinstance(changed, list) {
            for rel_path in changed {
                try {
                    fh = open(os.path.join(files_dir, str(rel_path)), "r");
                    try {
                        file_snapshots[str(rel_path)] = fh.read();
                    } finally {
                        fh.close();
                    }
                } except Exception {}
            }
        }
    }
    return {
        "metadata": metadata,
        "conversation": conversation,
        "fileSnapshots": file_snapshots,
    };
}


def _timestamp_key(item: dict) -> str {
    return str(item["metadata"].get("timestamp", ""));
}


"""All checkpoints for a project, newest-timestamped first. Entries are
{name, metadata, sizeBytes}; directories without readable metadata.json
are skipped."""
def list_checkpoints(cwd: str) -> list {
    cp_dir = checkpoints_dir(cwd);
    try {
        os.makedirs(cp_dir, exist_ok=True);
    } except OSError {}

    items: list = [];
    try {
        entries = os.listdir(cp_dir);
    } except OSError {
        return [];
    }

    for name_entry in entries {
        dir_path = os.path.join(cp_dir, name_entry);
        if not os.path.isdir(dir_path) {
            continue;
        }
        meta_path = os.path.join(dir_path, _METADATA_NAME);
        if not os.path.exists(meta_path) {
            continue;
        }
        try {
            metadata = _load_json_file(meta_path);
            items.append({
                "name": name_entry,
                "metadata": metadata,
                "sizeBytes": _dir_size(dir_path),
            });
        } except Exception {}
    }
    return sorted(items, key=_timestamp_key, reverse=True);
}


"""Remove one checkpoint directory. Raises ValueError when it is unknown."""
def delete_checkpoint(cwd: str, name: str) -> None {
    dir_path = _checkpoint_path(cwd, name);
    if not os.path.exists(dir_path) {
        raise ValueError("Checkpoint '" + name + "' does not exist");
    }
    shutil.rmtree(dir_path);
}


"""Write snapshot contents back under cwd, creating parent directories.
Collects per-file failures and raises one aggregated RuntimeError when
anything failed (partial writes are left in place, like the toolchain)."""
def restore_checkpoint_files(cwd: str, snapshots: dict[str, str]) -> None {
    errors: list[str] = [];
    for rel_path in snapshots {
        try {
            abs_path: str = _resolve_rel(cwd, str(rel_path));
            os.makedirs(_path_dirname(abs_path), exist_ok=True);
            fh: any = open(abs_path, "w");
            try {
                fh.write(snapshots[rel_path]);
            } finally {
                fh.close();
            }
        } except Exception as exc {
            errors.append("Failed to restore " + str(rel_path) + ": " + str(exc));
        }
    }
    if errors {
        raise RuntimeError("Failed to restore some files:\n" + "\n".join(errors));
    }
}


def _plural(n: int, unit: str) -> str {
    return str(n) + " " + unit + ("s" if n != 1 else "");
}


def _changed_count(m: dict) -> int {
    changed = m.get("filesChanged");
    if isinstance(changed, list) {
        return len(changed);
    }
    return 0;
}


"""Humanized age for an ISO timestamp: just now / N min(s) / N hr(s) /
N day(s) ago / bare YYYY-MM-DD past a week."""
def format_relative_time(timestamp: str) -> str {
    now = datetime.datetime.now(datetime.timezone.utc).timestamp();
    t = datetime.datetime.fromisoformat(timestamp).timestamp();
    diff_minutes = int((now - t) / 60);
    diff_hours = diff_minutes // 60;
    diff_days = diff_hours // 24;

    if diff_minutes < 1 {
        return "just now";
    }
    if diff_minutes < 60 {
        return _plural(diff_minutes, "min") + " ago";
    }
    if diff_hours < 24 {
        return _plural(diff_hours, "hr") + " ago";
    }
    if diff_days < 7 {
        return _plural(diff_days, "day") + " ago";
    }
    return datetime.datetime.fromisoformat(timestamp).strftime("%Y-%m-%d");
}


def _size_label(size_bytes: any) -> str {
    if size_bytes {
        return str(round(int(size_bytes) / 1024)) + "KB";
    }
    return "?";
}


"""One overlay line: <name> — <N> msgs, <N> files — <when> (<size>)."""
def format_checkpoint_overlay_row(item: dict) -> str {
    m = item["metadata"];
    when = format_relative_time(str(m["timestamp"]));
    size_kb = _size_label(item.get("sizeBytes"));
    return (
        str(m["name"]) + " \u2014 " + str(m["messageCount"]) + " msgs, "
        + str(_changed_count(m)) + " files \u2014 " + when
        + " (" + size_kb + ")"
    );
}


def format_checkpoint_list(items: list[dict]) -> str {
    if not items {
        return "No checkpoints. Use /checkpoint create [name].";
    }
    lines: list[str] = [];
    for item in items {
        m: dict = item["metadata"];
        when = datetime.datetime.fromisoformat(str(m["timestamp"])).strftime("%Y-%m-%d %H:%M");
        size_kb = _size_label(item.get("sizeBytes"));
        lines.append(
            "- " + str(m["name"]) + " (" + when + ", " + str(m["messageCount"])
            + " msgs, " + str(_changed_count(m)) + " files, " + size_kb + ")"
        );
    }
    return "Checkpoints:\n" + "\n".join(lines);
}
