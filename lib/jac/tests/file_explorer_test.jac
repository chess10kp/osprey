"""Tests for lib/jac/project/file_explorer.jac helpers."""

::py::
import os
import shutil
import sys as _sys
import tempfile
from pathlib import Path

_pkg = os.path.join(os.getcwd(), "lib", "jac", "project")
if _pkg not in _sys.path:
    _sys.path.insert(0, _pkg)

from _file_explorer_toolchain import (
    estimate_selection_chars,
    list_project_files,
)


def _mk_fixture() -> str:
    root = tempfile.mkdtemp(prefix="jackal-file-explorer-")
    Path(root, "keep.txt").write_text("ok", encoding="utf-8")
    Path(root, "ignored").mkdir(parents=True, exist_ok=True)
    Path(root, "ignored", "skip.txt").write_text("no", encoding="utf-8")
    Path(root, ".gitignore").write_text("ignored/\n", encoding="utf-8")
    return root


def _rm_fixture(path: str) -> None:
    shutil.rmtree(path, ignore_errors=True)
::py::

test "list_project_files skips .gitignore paths" {
    tmp_dir = _mk_fixture();
    files = list_project_files(tmp_dir);
    assert "keep.txt" in files;
    assert "ignored/skip.txt" not in files;
    _rm_fixture(tmp_dir);
}

test "estimate_selection_chars reports fallback for unreadable file" {
    tmp_dir = _mk_fixture();
    result = estimate_selection_chars(tmp_dir, ["keep.txt", "missing.txt"]);
    assert result["chars"] >= 102;
    assert result["tokens"] >= 26;
    _rm_fixture(tmp_dir);
}
