"""Tests for lib/jac/config/_project_config_toolchain.py."""

import json
import os
import tempfile

import sys

# Add config dir to path so we can import the toolchain module directly.
_config_dir = os.path.join(os.path.dirname(__file__), "..", "config")
if _config_dir not in sys.path:
    sys.path.insert(0, _config_dir)

from _project_config_toolchain import (
    find_config_path,
    load_project_config,
    resolve_default_mode,
)


def test_find_config_path_miss():
    with tempfile.TemporaryDirectory() as tmp:
        assert find_config_path(tmp) is None


def test_find_config_path_hit():
    with tempfile.TemporaryDirectory() as tmp:
        cfg = os.path.join(tmp, ".jackal")
        with open(cfg, "w") as f:
            json.dump({"autocheck": True}, f)
        assert find_config_path(tmp) == cfg


def test_find_config_path_walk_up():
    with tempfile.TemporaryDirectory() as tmp:
        cfg = os.path.join(tmp, ".jackal")
        with open(cfg, "w") as f:
            json.dump({}, f)
        child = os.path.join(tmp, "a", "b", "c")
        os.makedirs(child)
        assert find_config_path(child) == cfg


def test_load_project_config_empty():
    with tempfile.TemporaryDirectory() as tmp:
        result = load_project_config(tmp)
        assert result == {}


def test_load_project_config_valid():
    with tempfile.TemporaryDirectory() as tmp:
        with open(os.path.join(tmp, ".jackal"), "w") as f:
            json.dump({"autocheck": True, "mode": "plan", "maxFixAttempts": 5}, f)
        result = load_project_config(tmp)
        assert result["autocheck"] is True
        assert result["mode"] == "plan"
        assert result["maxFixAttempts"] == 5


def test_load_project_config_invalid_json():
    with tempfile.TemporaryDirectory() as tmp:
        with open(os.path.join(tmp, ".jackal"), "w") as f:
            f.write("not json!")
        result = load_project_config(tmp)
        assert result == {}


def test_load_project_config_non_dict():
    with tempfile.TemporaryDirectory() as tmp:
        with open(os.path.join(tmp, ".jackal"), "w") as f:
            json.dump([1, 2, 3], f)
        result = load_project_config(tmp)
        assert result == {}


def test_resolve_default_mode_normal():
    assert resolve_default_mode({}) == "normal"


def test_resolve_default_mode_plan_flag():
    assert resolve_default_mode({"plan": True}) == "plan"


def test_resolve_default_mode_mode_key():
    for mode in ("normal", "auto-accept", "yolo", "plan", "ask"):
        assert resolve_default_mode({"mode": mode}) == mode


def test_resolve_default_mode_invalid_mode_falls_through():
    # Invalid mode string falls through to plan: true check, then normal
    assert resolve_default_mode({"mode": "invalid"}) == "normal"
    assert resolve_default_mode({"mode": "invalid", "plan": True}) == "plan"


def test_resolve_default_mode_mode_overrides_plan():
    assert resolve_default_mode({"mode": "yolo", "plan": True}) == "yolo"
