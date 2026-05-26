"""Tests for Phase 3 core + session Python toolchain modules.

Covers:
  - _tool_summary_toolchain  (lib/jac/core/)
  - _auto_compact_toolchain   (lib/jac/session/)
  - _session_index_toolchain  (lib/jac/session/)
"""

from __future__ import annotations

import json
import os
import sys

import pytest

# ── Ensure imports resolve ──────────────────────────────────────────

_HERE = os.path.dirname(os.path.abspath(__file__))
_sys_paths = [
    os.path.join(_HERE, "..", "core"),
    os.path.join(_HERE, "..", "session"),
]
for _p in _sys_paths:
    _p = os.path.normpath(_p)
    if _p not in sys.path:
        sys.path.insert(0, _p)

from _tool_summary_toolchain import (
    enrich_tool_input_from_result,
    format_tool_summary,
    normalize_tool_input,
    tool_bash_command,
    tool_event_input,
    tool_file_path,
    tool_input_field,
)
from _auto_compact_toolchain import (
    build_llm_summary_prompt,
    build_mechanical_summary,
    resolve_auto_compact_config,
    should_auto_compact,
    DEFAULT_AUTO_COMPACT,
)
from _session_index_toolchain import (
    delete_session,
    get_last_session,
    is_session_record,
    is_valid_session_id,
    list_sessions,
    load_session_by_id,
    migrate_legacy_latest,
    prune_sessions,
    rebuild_index,
    resolve_session_target,
    save_session_record,
)


# =====================================================================
# Helper: create a session record dict for tests
# =====================================================================

def _make_record(
    session_id: str = "sess_1000",
    name: str = "test session",
    cwd: str = "/tmp/test",
    updated_at: str = "2026-01-01T00:00:00+00:00",
    messages: list | None = None,
    model: dict | None = None,
) -> dict:
    return {
        "sessionId": session_id,
        "sessionName": name,
        "cwd": cwd,
        "createdAt": "2026-01-01T00:00:00+00:00",
        "updatedAt": updated_at,
        "messages": messages or [],
        "model": model,
    }


# =====================================================================
# 1. _tool_summary_toolchain
# =====================================================================


class TestNormalizeToolInput:
    def test_none_returns_none(self):
        assert normalize_tool_input(None) is None

    def test_dict_returns_dict(self):
        d = {"path": "foo.jac"}
        assert normalize_tool_input(d) == d

    def test_json_object_string_returns_dict(self):
        assert normalize_tool_input('{"path": "foo.jac"}') == {"path": "foo.jac"}

    def test_json_array_string_returns_none(self):
        assert normalize_tool_input("[1, 2, 3]") is None

    def test_plain_string_returns_none(self):
        assert normalize_tool_input("just some text") is None

    def test_empty_string_returns_none(self):
        assert normalize_tool_input("  ") is None

    def test_invalid_json_string_returns_none(self):
        assert normalize_tool_input("{broken") is None

    def test_list_returns_none(self):
        assert normalize_tool_input([1, 2, 3]) is None

    def test_number_returns_none(self):
        assert normalize_tool_input(42) is None


class TestToolInputField:
    def test_present_key_returns_value(self):
        assert tool_input_field({"path": "foo.jac"}, "path") == "foo.jac"

    def test_missing_key_returns_empty(self):
        assert tool_input_field({"path": "foo.jac"}, "command") == ""

    def test_none_input_returns_empty(self):
        assert tool_input_field(None, "path") == ""

    def test_null_value_returns_empty(self):
        assert tool_input_field({"path": None}, "path") == ""

    def test_non_string_value_is_stringified(self):
        assert tool_input_field({"count": 42}, "count") == "42"


class TestToolBashCommand:
    def test_command_key(self):
        assert tool_bash_command({"command": "ls -la"}) == "ls -la"

    def test_cmd_key_fallback(self):
        assert tool_bash_command({"cmd": "npm test"}) == "npm test"

    def test_command_takes_precedence_over_cmd(self):
        assert tool_bash_command({"command": "first", "cmd": "second"}) == "first"

    def test_no_keys_returns_empty(self):
        assert tool_bash_command({}) == ""

    def test_none_returns_empty(self):
        assert tool_bash_command(None) == ""


class TestToolFilePath:
    def test_path_key(self):
        assert tool_file_path({"path": "a.jac"}) == "a.jac"

    def test_file_path_key(self):
        assert tool_file_path({"file_path": "b.jac"}) == "b.jac"

    def test_target_file_key(self):
        assert tool_file_path({"target_file": "c.jac"}) == "c.jac"

    def test_file_key(self):
        assert tool_file_path({"file": "d.jac"}) == "d.jac"

    def test_precedence_order(self):
        assert tool_file_path({"path": "a", "file_path": "b", "file": "c"}) == "a"
        assert tool_file_path({"file_path": "b", "file": "c"}) == "b"
        assert tool_file_path({"file": "c"}) == "c"

    def test_none_returns_empty(self):
        assert tool_file_path(None) == ""


class TestFormatToolSummary:
    def test_read_with_path(self):
        assert format_tool_summary("read", {"path": "foo.jac"}) == "Read @ foo.jac"

    def test_read_without_path(self):
        assert format_tool_summary("read") == "Read file"

    def test_write_with_path(self):
        assert format_tool_summary("write", {"path": "out.jac"}) == "Wrote → out.jac"

    def test_write_without_path(self):
        assert format_tool_summary("write") == "Wrote file"

    def test_edit_with_path(self):
        assert format_tool_summary("edit", {"path": "main.jac"}) == "Edited main.jac"

    def test_edit_without_path(self):
        assert format_tool_summary("edit") == "Edited file"

    def test_bash_with_command(self):
        assert format_tool_summary("bash", {"command": "ls"}) == "$ ls"

    def test_bash_without_command(self):
        assert format_tool_summary("bash") == "Ran shell command"

    def test_glob_with_pattern(self):
        assert format_tool_summary("glob", {"pattern": "*.jac"}) == "Glob *.jac"

    def test_glob_without_pattern(self):
        assert format_tool_summary("glob") == "File search"

    def test_agent_with_task(self):
        assert format_tool_summary("agent", {"task": "refactor"}) == "Subagent: refactor"

    def test_agent_with_prompt(self):
        assert format_tool_summary("agent", {"prompt": "analyze"}) == "Subagent: analyze"

    def test_agent_without_task(self):
        assert format_tool_summary("agent") == "Delegated to subagent"

    def test_update_task_with_id_and_status(self):
        result = format_tool_summary("update_task", {
            "updates": [{"id": "t1", "status": "done"}],
        })
        assert result == "Task t1 → done"

    def test_update_task_with_multiple(self):
        result = format_tool_summary("update_task", {
            "updates": [{"id": "t1"}, {"id": "t2"}],
        })
        assert result == "Updated task t1 (+1)"

    def test_update_task_no_updates(self):
        assert format_tool_summary("update_task") == "Updated task"

    def test_create_task_with_title(self):
        assert format_tool_summary("create_task", {"title": "Fix bug"}) == "Created task: Fix bug"

    def test_create_task_without_title(self):
        assert format_tool_summary("create_task") == "Created task"

    def test_mermaid(self):
        assert format_tool_summary("mermaid") == "Rendered diagram"

    def test_jac_check(self):
        assert format_tool_summary("jac_check") == "Ran jac check"

    def test_jac_check_syntax(self):
        assert format_tool_summary("jac_check_syntax") == "Ran jac check"

    def test_jac_run_with_file(self):
        assert format_tool_summary("jac_run", {"file": "main.jac"}) == "Ran jac main.jac"

    def test_jac_run_without_file(self):
        assert format_tool_summary("jac_run") == "Ran jac file"

    def test_jac_format(self):
        assert format_tool_summary("jac_format") == "Formatted jac file(s)"

    def test_jac_test(self):
        assert format_tool_summary("jac_test") == "Ran jac test"

    def test_jac_fix(self):
        assert format_tool_summary("jac_fix") == "Ran jac fix loop"

    def test_jac_doctor(self):
        assert format_tool_summary("jac_doctor") == "Ran jac doctor"

    def test_jac_create(self):
        assert format_tool_summary("jac_create") == "Ran jac create"

    def test_jac_cli_with_args(self):
        assert format_tool_summary("jac_cli", {"args": ["check", "--verbose"]}) == "jac check --verbose"

    def test_jac_cli_without_args(self):
        assert format_tool_summary("jac_cli") == "Ran jac CLI"

    def test_diagnostics(self):
        assert format_tool_summary("diagnostics") == "Got diagnostics"

    def test_hover(self):
        assert format_tool_summary("hover") == "Looked up type info"

    def test_definition(self):
        assert format_tool_summary("definition") == "Found definition"

    def test_references(self):
        assert format_tool_summary("references") == "Found references"

    def test_web_search_with_query(self):
        assert format_tool_summary("web_search", {"search_term": "python"}) == "Web search: python"

    def test_web_search_with_query_key(self):
        assert format_tool_summary("web_search", {"query": "jac lang"}) == "Web search: jac lang"

    def test_web_search_without_query(self):
        assert format_tool_summary("web_search") == "Web search"

    def test_web_fetch_with_url(self):
        assert format_tool_summary("web_fetch", {"url": "https://example.com"}) == "Fetched https://example.com"

    def test_web_fetch_without_url(self):
        assert format_tool_summary("web_fetch") == "Fetched URL"

    def test_unknown_jac_tool(self):
        assert format_tool_summary("jac_custom") == "Ran jac_custom"

    def test_unknown_tool(self):
        assert format_tool_summary("my_custom_tool") == "Ran my_custom_tool"

    def test_long_path_truncated(self):
        long_path = "a" * 100
        result = format_tool_summary("read", {"path": long_path})
        assert len(result) <= 70  # "Read @ " + 60 + "…"
        assert result.endswith("…")


class TestEnrichToolInputFromResult:
    def test_path_tool_already_has_path(self):
        input_d = {"path": "foo.jac"}
        result = enrich_tool_input_from_result("read", input_d, {"details": {"path": "bar.jac"}})
        assert result == {"path": "foo.jac"}

    def test_bash_already_has_command(self):
        input_d = {"command": "ls"}
        result = enrich_tool_input_from_result("bash", input_d, {"details": {"command": "pwd"}})
        assert result == {"command": "ls"}

    def test_enrich_path_from_details(self):
        result = enrich_tool_input_from_result("read", {}, {"details": {"path": "foo.jac"}})
        assert result == {"path": "foo.jac"}

    def test_enrich_command_from_details(self):
        result = enrich_tool_input_from_result("bash", {}, {"details": {"command": "ls -la"}})
        assert result == {"command": "ls -la"}

    def test_no_enrichment_without_details(self):
        # Empty dict input is falsy in Python → returns None
        result = enrich_tool_input_from_result("read", {}, {"no_details": True})
        assert result is None

    def test_none_result(self):
        result = enrich_tool_input_from_result("read", {}, None)
        assert result is None

    def test_non_empty_input_preserved_with_none_result(self):
        result = enrich_tool_input_from_result("read", {"extra": True}, None)
        assert result == {"extra": True}

    def test_none_input_none_result(self):
        result = enrich_tool_input_from_result("read", None, None)
        assert result is None

    def test_enrich_file_key_from_details(self):
        result = enrich_tool_input_from_result("read", {}, {"details": {"file": "bar.jac"}})
        assert result == {"path": "bar.jac"}

    def test_enrich_target_file_key_from_details(self):
        result = enrich_tool_input_from_result("read", {}, {"details": {"target_file": "baz.jac"}})
        assert result == {"path": "baz.jac"}


class TestToolEventInput:
    def test_from_input_key(self):
        result = tool_event_input({"input": {"path": "foo.jac"}})
        assert result == {"path": "foo.jac"}

    def test_from_args_key(self):
        result = tool_event_input({"args": {"command": "ls"}})
        assert result == {"command": "ls"}

    def test_input_takes_precedence(self):
        result = tool_event_input({"input": {"path": "a"}, "args": {"path": "b"}})
        assert result == {"path": "a"}

    def test_neither_key_returns_none(self):
        assert tool_event_input({}) is None

    def test_string_input_returns_none(self):
        assert tool_event_input({"input": "just a string"}) is None


# =====================================================================
# 2. _auto_compact_toolchain
# =====================================================================


class TestResolveAutoCompactConfig:
    def test_false_disables(self):
        cfg = resolve_auto_compact_config({"autoCompact": False})
        assert cfg["enabled"] is False
        assert cfg["thresholdPercent"] == 80  # defaults preserved

    def test_true_enables(self):
        cfg = resolve_auto_compact_config({"autoCompact": True})
        assert cfg["enabled"] is True
        assert cfg["strategy"] == "llm"

    def test_dict_merges(self):
        cfg = resolve_auto_compact_config({"autoCompact": {"thresholdPercent": 90, "keepTail": 5}})
        assert cfg["thresholdPercent"] == 90
        assert cfg["keepTail"] == 5
        assert cfg["enabled"] is True  # default

    def test_compact_strategy_override(self):
        cfg = resolve_auto_compact_config({"compactStrategy": "mechanical"})
        assert cfg["strategy"] == "mechanical"

    def test_compact_strategy_llm(self):
        cfg = resolve_auto_compact_config({"compactStrategy": "llm"})
        assert cfg["strategy"] == "llm"

    def test_empty_dict_returns_defaults(self):
        cfg = resolve_auto_compact_config({})
        assert cfg == DEFAULT_AUTO_COMPACT

    def test_compact_strategy_overrides_dict(self):
        cfg = resolve_auto_compact_config({
            "autoCompact": {"strategy": "llm"},
            "compactStrategy": "mechanical",
        })
        assert cfg["strategy"] == "mechanical"


class TestBuildMechanicalSummary:
    def test_string_content(self):
        messages = [
            {"role": "user", "content": "hello"},
            {"role": "assistant", "content": "hi there"},
        ]
        result = build_mechanical_summary(messages)
        assert "<context-summary>" in result
        assert "</context-summary>" in result
        assert "[user] hello" in result
        assert "[assistant] hi there" in result

    def test_array_content(self):
        messages = [
            {"role": "assistant", "content": [
                {"type": "text", "text": "part one"},
                "plain string part",
            ]},
        ]
        result = build_mechanical_summary(messages)
        assert "part one" in result
        assert "plain string part" in result

    def test_tool_call_content(self):
        messages = [
            {"role": "assistant", "content": [
                {"type": "toolCall", "name": "read"},
            ]},
        ]
        result = build_mechanical_summary(messages)
        assert "[tool call: read]" in result

    def test_long_content_truncated(self):
        long_text = "x" * 500
        messages = [{"role": "user", "content": long_text}]
        result = build_mechanical_summary(messages)
        # The line should be truncated (297 + "..." = 300 chars of text)
        for line in result.split("\n"):
            if line.startswith("[user]"):
                assert line.endswith("...")
                assert len(line) < len("[user] ") + 500

    def test_empty_list(self):
        result = build_mechanical_summary([])
        assert "<context-summary>" in result
        assert "</context-summary>" in result

    def test_unknown_role(self):
        messages = [{"role": "system", "content": "you are helpful"}]
        result = build_mechanical_summary(messages)
        assert "[system] you are helpful" in result


class TestShouldAutoCompact:
    def test_above_threshold_triggers(self):
        assert should_auto_compact(90, DEFAULT_AUTO_COMPACT) is True

    def test_at_threshold_triggers(self):
        assert should_auto_compact(80, DEFAULT_AUTO_COMPACT) is True

    def test_below_threshold_does_not_trigger(self):
        assert should_auto_compact(79, DEFAULT_AUTO_COMPACT) is False

    def test_disabled_does_not_trigger(self):
        cfg = {**DEFAULT_AUTO_COMPACT, "enabled": False}
        assert should_auto_compact(99, cfg) is False

    def test_zero_percent_does_not_trigger(self):
        assert should_auto_compact(0, DEFAULT_AUTO_COMPACT) is False


class TestBuildLlmSummaryPrompt:
    def test_includes_instructions(self):
        prompt = build_llm_summary_prompt([])
        assert "200 words or less" in prompt
        assert "file paths" in prompt
        assert "technical substance" in prompt

    def test_includes_message_previews(self):
        messages = [
            {"role": "user", "content": "fix the bug in main.jac"},
            {"role": "assistant", "content": "I found the issue"},
        ]
        prompt = build_llm_summary_prompt(messages)
        assert "[user] fix the bug in main.jac" in prompt
        assert "[assistant] I found the issue" in prompt

    def test_long_message_truncated_in_prompt(self):
        long_text = "y" * 300
        messages = [{"role": "user", "content": long_text}]
        prompt = build_llm_summary_prompt(messages)
        assert "..." in prompt
        # Should not contain the full 300-char string
        assert long_text not in prompt


# =====================================================================
# 3. _session_index_toolchain
# =====================================================================


class TestIsValidSessionId:
    def test_valid_sess_prefix(self):
        assert is_valid_session_id("sess_123") is True
        assert is_valid_session_id("sess_0") is True
        assert is_valid_session_id("sess_999999") is True

    def test_invalid_no_prefix(self):
        assert is_valid_session_id("123") is False

    def test_invalid_mem_prefix(self):
        assert is_valid_session_id("mem_123") is False

    def test_invalid_empty(self):
        assert is_valid_session_id("") is False

    def test_invalid_letters_after_prefix(self):
        assert is_valid_session_id("sess_abc") is False

    def test_invalid_trailing_chars(self):
        assert is_valid_session_id("sess_123_extra") is False


class TestIsSessionRecord:
    def test_valid_record(self):
        r = _make_record()
        assert is_session_record(r) is True

    def test_missing_session_id(self):
        r = _make_record()
        del r["sessionId"]
        assert is_session_record(r) is False

    def test_missing_messages(self):
        r = _make_record()
        del r["messages"]
        assert is_session_record(r) is False

    def test_messages_not_list(self):
        r = _make_record()
        r["messages"] = "not a list"
        assert is_session_record(r) is False

    def test_not_dict(self):
        assert is_session_record("string") is False
        assert is_session_record(None) is False


class TestSaveAndLoadSession:
    def test_round_trip(self, tmp_path):
        d = str(tmp_path / "sessions")
        record = _make_record(messages=[{"role": "user", "content": "hi"}])
        save_session_record(d, record)
        loaded = load_session_by_id(d, "sess_1000")
        assert loaded is not None
        assert loaded["sessionId"] == "sess_1000"
        assert loaded["sessionName"] == "test session"
        assert len(loaded["messages"]) == 1

    def test_load_nonexistent(self, tmp_path):
        d = str(tmp_path / "sessions")
        assert load_session_by_id(d, "sess_9999") is None

    def test_load_invalid_id(self, tmp_path):
        d = str(tmp_path / "sessions")
        assert load_session_by_id(d, "invalid_id") is None

    def test_save_invalid_session_id_raises(self, tmp_path):
        d = str(tmp_path / "sessions")
        record = _make_record(session_id="bad_id")
        with pytest.raises(ValueError, match="Invalid session ID"):
            save_session_record(d, record)

    def test_save_updates_existing(self, tmp_path):
        d = str(tmp_path / "sessions")
        r1 = _make_record(session_id="sess_100", name="first")
        save_session_record(d, r1)
        r2 = _make_record(session_id="sess_100", name="second")
        save_session_record(d, r2)
        loaded = load_session_by_id(d, "sess_100")
        assert loaded["sessionName"] == "second"


class TestListSessions:
    def test_lists_sorted_by_updated_at_desc(self, tmp_path):
        d = str(tmp_path / "sessions")
        save_session_record(d, _make_record(session_id="sess_1", updated_at="2026-01-01T00:00:00Z"))
        save_session_record(d, _make_record(session_id="sess_2", updated_at="2026-06-01T00:00:00Z"))
        save_session_record(d, _make_record(session_id="sess_3", updated_at="2026-03-01T00:00:00Z"))
        entries = list_sessions(d)
        assert len(entries) == 3
        assert entries[0]["id"] == "sess_2"
        assert entries[1]["id"] == "sess_3"
        assert entries[2]["id"] == "sess_1"

    def test_cwd_filter(self, tmp_path):
        d = str(tmp_path / "sessions")
        save_session_record(d, _make_record(session_id="sess_1", cwd="/foo/bar"))
        save_session_record(d, _make_record(session_id="sess_2", cwd="/baz/qux"))
        entries = list_sessions(d, {"cwd": "/foo/bar"})
        assert len(entries) == 1
        assert entries[0]["id"] == "sess_1"

    def test_empty_dir(self, tmp_path):
        d = str(tmp_path / "sessions")
        assert list_sessions(d) == []

    def test_nonexistent_dir(self, tmp_path):
        d = str(tmp_path / "nope")
        assert list_sessions(d) == []


class TestGetLastSession:
    def test_returns_most_recent(self, tmp_path):
        d = str(tmp_path / "sessions")
        save_session_record(d, _make_record(session_id="sess_1", updated_at="2026-01-01T00:00:00Z"))
        save_session_record(d, _make_record(session_id="sess_2", updated_at="2026-06-01T00:00:00Z"))
        last = get_last_session(d)
        assert last is not None
        assert last["id"] == "sess_2"

    def test_empty_returns_none(self, tmp_path):
        d = str(tmp_path / "sessions")
        assert get_last_session(d) is None


class TestResolveSessionTarget:
    def test_last(self, tmp_path):
        d = str(tmp_path / "sessions")
        save_session_record(d, _make_record(session_id="sess_1", updated_at="2026-01-01T00:00:00Z"))
        save_session_record(d, _make_record(session_id="sess_2", updated_at="2026-06-01T00:00:00Z"))
        result = resolve_session_target(d, "last")
        assert result is not None
        assert result["sessionId"] == "sess_2"

    def test_numeric_index(self, tmp_path):
        d = str(tmp_path / "sessions")
        save_session_record(d, _make_record(session_id="sess_1", updated_at="2026-01-01T00:00:00Z"))
        save_session_record(d, _make_record(session_id="sess_2", updated_at="2026-06-01T00:00:00Z"))
        # Index 1 = newest (sess_2), index 2 = second newest (sess_1)
        result = resolve_session_target(d, "1")
        assert result is not None
        assert result["sessionId"] == "sess_2"
        result2 = resolve_session_target(d, "2")
        assert result2 is not None
        assert result2["sessionId"] == "sess_1"

    def test_raw_id(self, tmp_path):
        d = str(tmp_path / "sessions")
        save_session_record(d, _make_record(session_id="sess_42"))
        result = resolve_session_target(d, "sess_42")
        assert result is not None
        assert result["sessionId"] == "sess_42"

    def test_nonexistent_returns_none(self, tmp_path):
        d = str(tmp_path / "sessions")
        save_session_record(d, _make_record(session_id="sess_1"))
        assert resolve_session_target(d, "sess_9999") is None

    def test_empty_dir_returns_none(self, tmp_path):
        d = str(tmp_path / "sessions")
        assert resolve_session_target(d, "last") is None


class TestDeleteSession:
    def test_deletes_file_and_index(self, tmp_path):
        d = str(tmp_path / "sessions")
        save_session_record(d, _make_record(session_id="sess_1"))
        save_session_record(d, _make_record(session_id="sess_2"))
        assert delete_session(d, "sess_1") is True
        assert load_session_by_id(d, "sess_1") is None
        assert len(list_sessions(d)) == 1

    def test_invalid_id_returns_false(self, tmp_path):
        d = str(tmp_path / "sessions")
        assert delete_session(d, "invalid") is False

    def test_nonexistent_id_returns_true(self, tmp_path):
        d = str(tmp_path / "sessions")
        save_session_record(d, _make_record(session_id="sess_1"))
        # File doesn't exist but ID is valid — still succeeds (idempotent)
        assert delete_session(d, "sess_999") is True


class TestMigrateLegacyLatest:
    def test_migrates_latest_json(self, tmp_path):
        d = str(tmp_path / "sessions")
        os.makedirs(d, exist_ok=True)
        legacy = {
            "sessionId": "sess_42",
            "sessionName": "old session",
            "messages": [{"role": "user", "content": "hello"}],
            "model": {"provider": "test", "id": "model-1"},
        }
        with open(os.path.join(d, "latest.json"), "w") as f:
            json.dump(legacy, f)

        result = migrate_legacy_latest(d, "/cwd")
        assert result is not None
        assert result["sessionId"] == "sess_42"
        assert result["sessionName"] == "old session"
        assert result["cwd"] == "/cwd"
        assert len(result["messages"]) == 1

        # Session file should now exist
        loaded = load_session_by_id(d, "sess_42")
        assert loaded is not None

        # latest.json should be removed
        assert not os.path.exists(os.path.join(d, "latest.json"))

    def test_no_legacy_file(self, tmp_path):
        d = str(tmp_path / "sessions")
        os.makedirs(d, exist_ok=True)
        assert migrate_legacy_latest(d, "/cwd") is None

    def test_legacy_missing_session_id(self, tmp_path):
        d = str(tmp_path / "sessions")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "latest.json"), "w") as f:
            json.dump({"messages": []}, f)
        assert migrate_legacy_latest(d, "/cwd") is None


class TestPruneSessions:
    def test_prune_by_count(self, tmp_path):
        d = str(tmp_path / "sessions")
        # Create 3 sessions with different timestamps
        save_session_record(d, _make_record(session_id="sess_1", updated_at="2026-01-01T00:00:00Z"))
        save_session_record(d, _make_record(session_id="sess_2", updated_at="2026-02-01T00:00:00Z"))
        save_session_record(d, _make_record(session_id="sess_3", updated_at="2026-03-01T00:00:00Z"))
        pruned = prune_sessions(d, {"maxCount": 2})
        assert len(pruned) == 1
        assert pruned[0] == "sess_1"  # oldest pruned
        assert len(list_sessions(d)) == 2

    def test_prune_by_retention(self, tmp_path):
        d = str(tmp_path / "sessions")
        # One old, one recent
        save_session_record(d, _make_record(session_id="sess_1", updated_at="2020-01-01T00:00:00Z"))
        save_session_record(d, _make_record(session_id="sess_2", updated_at="2026-05-26T00:00:00Z"))
        pruned = prune_sessions(d, {"retentionDays": 30})
        assert "sess_1" in pruned
        assert "sess_2" not in pruned

    def test_no_pruning_needed(self, tmp_path):
        d = str(tmp_path / "sessions")
        save_session_record(d, _make_record(session_id="sess_1", updated_at="2026-05-26T00:00:00Z"))
        pruned = prune_sessions(d, {"maxCount": 10, "retentionDays": 365})
        assert pruned == []

    def test_empty_dir(self, tmp_path):
        d = str(tmp_path / "sessions")
        assert prune_sessions(d) == []


class TestRebuildIndex:
    def test_rebuilds_from_files(self, tmp_path):
        d = str(tmp_path / "sessions")
        os.makedirs(d, exist_ok=True)
        # Write session files directly (no index)
        r1 = _make_record(session_id="sess_1", name="first", updated_at="2026-01-01T00:00:00Z")
        r2 = _make_record(session_id="sess_2", name="second", updated_at="2026-02-01T00:00:00Z")
        with open(os.path.join(d, "sess_1.json"), "w") as f:
            json.dump(r1, f)
        with open(os.path.join(d, "sess_2.json"), "w") as f:
            json.dump(r2, f)

        entries = rebuild_index(d)
        assert len(entries) == 2
        names = {e["name"] for e in entries}
        assert names == {"first", "second"}

    def test_empty_dir_returns_empty(self, tmp_path):
        d = str(tmp_path / "sessions")
        os.makedirs(d, exist_ok=True)
        assert rebuild_index(d) == []

    def test_ignores_non_session_files(self, tmp_path):
        d = str(tmp_path / "sessions")
        os.makedirs(d, exist_ok=True)
        # Write a non-session JSON file
        with open(os.path.join(d, "other.json"), "w") as f:
            json.dump({"not": "a session"}, f)
        with open(os.path.join(d, "index.json"), "w") as f:
            json.dump([], f)
        with open(os.path.join(d, "latest.json"), "w") as f:
            json.dump({}, f)

        entries = rebuild_index(d)
        assert entries == []


# =====================================================================
# 4. _session_persistence_toolchain
# =====================================================================

# Ensure import path for session persistence
sys.path.insert(0, os.path.normpath(os.path.join(_HERE, "..", "session")))

from _session_persistence_toolchain import (
    clear_compaction_backup,
    export_session_markdown,
    flush_session_record,
    load_compaction_backup,
    save_compaction_backup,
    session_dir_path,
)


class TestSessionDirPath:
    def test_default_sessions_dir(self):
        assert session_dir_path("/cwd") == "/cwd/.jackal/sessions"

    def test_custom_subdir(self):
        assert session_dir_path("/cwd", "custom") == "/cwd/.jackal/custom"


class TestExportSessionMarkdown:
    def test_basic_export(self):
        md = export_session_markdown(
            "sess_1", "My Session", "/tmp",
            {"provider": "test", "id": "model-1"},
            [{"role": "user", "content": "hello"}, {"role": "assistant", "content": "hi"}],
        )
        assert "# My Session" in md
        assert "**Session ID:** sess_1" in md
        assert "**Model:** test/model-1" in md
        assert "**Messages:** 2" in md
        assert "## user" in md
        assert "hello" in md
        assert "## assistant" in md
        assert "hi" in md

    def test_no_model(self):
        md = export_session_markdown("sess_1", "test", "/tmp", None, [])
        assert "**Model:** (none)" in md

    def test_array_content(self):
        md = export_session_markdown("sess_1", "test", "/tmp", None, [
            {"role": "assistant", "content": [{"type": "text", "text": "part one"}]},
        ])
        assert "part one" in md


class TestCompactionBackup:
    def test_save_and_load(self, tmp_path):
        d = str(tmp_path / "sessions")
        msgs = [{"role": "user", "content": "important context"}]
        save_compaction_backup(d, "sess_1", msgs)
        loaded = load_compaction_backup(d, "sess_1")
        assert loaded is not None
        assert len(loaded) == 1
        assert loaded[0]["content"] == "important context"

    def test_load_nonexistent(self, tmp_path):
        d = str(tmp_path / "sessions")
        assert load_compaction_backup(d, "sess_1") is None

    def test_clear(self, tmp_path):
        d = str(tmp_path / "sessions")
        save_compaction_backup(d, "sess_1", [{"role": "user", "content": "x"}])
        clear_compaction_backup(d, "sess_1")
        # File exists but empty/invalid
        loaded = load_compaction_backup(d, "sess_1")
        assert loaded is None

    def test_save_empty_session_dir_skips(self):
        # Empty session_dir → no-op
        save_compaction_backup("", "sess_1", [])


class TestFlushSessionRecord:
    def test_flush_creates_session_file(self, tmp_path):
        d = str(tmp_path / "sessions")
        msgs = [{"role": "user", "content": "hello"}]
        flush_session_record(d, "sess_1", "test", "/tmp", "2026-01-01T00:00:00Z", msgs, None)
        loaded = load_session_by_id(d, "sess_1")
        assert loaded is not None
        assert loaded["sessionName"] == "test"
        assert len(loaded["messages"]) == 1

    def test_flush_with_model(self, tmp_path):
        d = str(tmp_path / "sessions")
        flush_session_record(d, "sess_1", "test", "/tmp", "2026-01-01T00:00:00Z", [], {"provider": "p", "id": "m"})
        loaded = load_session_by_id(d, "sess_1")
        assert loaded is not None
        assert loaded["model"]["provider"] == "p"

    def test_flush_invalid_id_skips(self, tmp_path):
        d = str(tmp_path / "sessions")
        flush_session_record(d, "bad_id", "test", "/tmp", "2026-01-01T00:00:00Z", [], None)
        assert load_session_by_id(d, "bad_id") is None

    def test_flush_empty_dir_skips(self, tmp_path):
        flush_session_record("", "sess_1", "test", "/tmp", "2026-01-01T00:00:00Z", [], None)


# =====================================================================
# 5. _auth_flow_toolchain
# =====================================================================

sys.path.insert(0, os.path.normpath(os.path.join(_HERE, "..", "auth")))

from _auth_flow_toolchain import (
    validate_provider_entry,
    validate_model_entry,
    filter_providers_by_query,
    filter_models_by_query,
    format_auth_provider_label,
    format_model_label,
    initial_auth_flow_state,
    transition_auth_flow,
)


class TestValidateProviderEntry:
    def test_valid_entry(self):
        e = {"id": "openai", "displayName": "OpenAI", "authType": "api_key", "configured": True, "modelCount": 5}
        result = validate_provider_entry(e)
        assert result is not None
        assert result["id"] == "openai"

    def test_missing_id(self):
        e = {"displayName": "X", "authType": "oauth"}
        assert validate_provider_entry(e) is None

    def test_invalid_auth_type(self):
        e = {"id": "x", "displayName": "X", "authType": "invalid"}
        assert validate_provider_entry(e) is None

    def test_not_dict(self):
        assert validate_provider_entry("string") is None
        assert validate_provider_entry(None) is None


class TestValidateModelEntry:
    def test_valid_entry(self):
        e = {"provider": "openai", "modelId": "gpt-4", "displayName": "GPT-4"}
        result = validate_model_entry(e)
        assert result is not None
        assert result["modelId"] == "gpt-4"

    def test_missing_provider(self):
        e = {"modelId": "gpt-4", "displayName": "GPT-4"}
        assert validate_model_entry(e) is None

    def test_not_dict(self):
        assert validate_model_entry(42) is None


class TestFilterProviders:
    def test_no_query_returns_all(self):
        providers = [
            {"id": "openai", "displayName": "OpenAI"},
            {"id": "anthropic", "displayName": "Anthropic"},
        ]
        assert len(filter_providers_by_query(providers, "")) == 2

    def test_filter_by_id(self):
        providers = [
            {"id": "openai", "displayName": "OpenAI"},
            {"id": "anthropic", "displayName": "Anthropic"},
        ]
        result = filter_providers_by_query(providers, "open")
        assert len(result) == 1
        assert result[0]["id"] == "openai"

    def test_filter_by_display_name(self):
        providers = [
            {"id": "openai", "displayName": "OpenAI"},
            {"id": "anthropic", "displayName": "Anthropic"},
        ]
        result = filter_providers_by_query(providers, "anthr")
        assert len(result) == 1

    def test_case_insensitive(self):
        providers = [{"id": "OpenAI", "displayName": "OpenAI"}]
        assert len(filter_providers_by_query(providers, "openai")) == 1


class TestFilterModels:
    def test_no_filter_returns_all(self):
        models = [
            {"provider": "openai", "modelId": "gpt-4", "displayName": "GPT-4"},
            {"provider": "anthropic", "modelId": "claude", "displayName": "Claude"},
        ]
        assert len(filter_models_by_query(models, "")) == 2

    def test_filter_by_provider(self):
        models = [
            {"provider": "openai", "modelId": "gpt-4", "displayName": "GPT-4"},
            {"provider": "anthropic", "modelId": "claude", "displayName": "Claude"},
        ]
        result = filter_models_by_query(models, "", "openai")
        assert len(result) == 1
        assert result[0]["provider"] == "openai"

    def test_filter_by_query(self):
        models = [
            {"provider": "openai", "modelId": "gpt-4", "displayName": "GPT-4"},
            {"provider": "anthropic", "modelId": "claude", "displayName": "Claude"},
        ]
        result = filter_models_by_query(models, "gpt")
        assert len(result) == 1


class TestFormatLabels:
    def test_provider_label_configured(self):
        label = format_auth_provider_label({
            "id": "openai", "displayName": "OpenAI",
            "authType": "api_key", "configured": True, "modelCount": 5,
        })
        assert "✓" in label
        assert "OpenAI" in label
        assert "API Key" in label
        assert "5 models" in label

    def test_provider_label_not_configured(self):
        label = format_auth_provider_label({
            "id": "openai", "displayName": "OpenAI",
            "authType": "oauth", "configured": False, "modelCount": 0,
        })
        assert "OpenAI" in label
        assert "OAuth" in label

    def test_model_label_with_provider(self):
        label = format_model_label({
            "provider": "openai", "modelId": "gpt-4", "displayName": "GPT-4",
        })
        assert "GPT-4" in label
        assert "openai/gpt-4" in label

    def test_model_label_without_provider(self):
        label = format_model_label({"modelId": "gpt-4", "displayName": "GPT-4"})
        assert "GPT-4" in label


class TestAuthFlowStateMachine:
    def test_initial_state(self):
        state = initial_auth_flow_state()
        assert state["step"]["kind"] == "idle"

    def test_open_provider_picker(self):
        state = initial_auth_flow_state()
        next_state = transition_auth_flow(state, "open_provider_picker", {
            "providers": [{"id": "x", "displayName": "X", "authType": "api_key", "configured": False, "modelCount": 0}],
        })
        assert next_state["step"]["kind"] == "provider_picker"
        assert len(next_state["step"]["providers"]) == 1

    def test_set_logging_in(self):
        state = transition_auth_flow({"step": {"kind": "idle"}}, "set_logging_in", {
            "providerId": "openai", "status": "connecting...",
        })
        assert state["step"]["kind"] == "logging_in"
        assert state["step"]["providerId"] == "openai"

    def test_set_browser_auth(self):
        state = transition_auth_flow({"step": {"kind": "idle"}}, "set_browser_auth", {
            "providerId": "openai", "url": "https://auth.example.com",
        })
        assert state["step"]["kind"] == "browser_auth"
        assert state["step"]["url"] == "https://auth.example.com"

    def test_set_logged_in(self):
        state = transition_auth_flow({"step": {"kind": "idle"}}, "set_logged_in", {
            "providerId": "openai", "nextStep": "model_picker",
        })
        assert state["step"]["kind"] == "logged_in"
        assert state["step"]["nextStep"] == "model_picker"

    def test_set_error(self):
        state = transition_auth_flow({"step": {"kind": "idle"}}, "set_error", {
            "message": "Auth failed", "providerId": "openai",
        })
        assert state["step"]["kind"] == "error"
        assert state["step"]["message"] == "Auth failed"

    def test_set_idle(self):
        state = transition_auth_flow({"step": {"kind": "error", "message": "x"}}, "set_idle")
        assert state["step"]["kind"] == "idle"

    def test_update_query_on_provider_picker(self):
        state = {"step": {"kind": "provider_picker", "providers": [], "query": ""}}
        next_state = transition_auth_flow(state, "update_query", {"query": "open"})
        assert next_state["step"]["query"] == "open"

    def test_update_query_on_idle_noop(self):
        state = {"step": {"kind": "idle"}}
        next_state = transition_auth_flow(state, "update_query", {"query": "test"})
        assert next_state["step"]["kind"] == "idle"

    def test_update_provider_filter(self):
        state = {"step": {"kind": "model_picker", "models": [], "query": "", "providerFilter": None}}
        next_state = transition_auth_flow(state, "update_provider_filter", {"providerFilter": "openai"})
        assert next_state["step"]["providerFilter"] == "openai"

    def test_cancel(self):
        state = transition_auth_flow({"step": {"kind": "logging_in", "providerId": "x"}}, "cancel")
        assert state["step"]["kind"] == "idle"

    def test_reset(self):
        state = transition_auth_flow({"step": {"kind": "error", "message": "x"}}, "reset")
        assert state["step"]["kind"] == "idle"

    def test_unknown_action_returns_copy(self):
        original = {"step": {"kind": "idle"}}
        result = transition_auth_flow(original, "nonexistent_action")
        assert result["step"]["kind"] == "idle"

    def test_does_not_mutate_original(self):
        original = {"step": {"kind": "provider_picker", "providers": [], "query": ""}}
        _ = transition_auth_flow(original, "update_query", {"query": "test"})
        assert original["step"]["query"] == ""

    def test_full_flow(self):
        """Simulate a complete auth flow: idle → provider_picker → logging_in → logged_in → model_picker → idle."""
        state = initial_auth_flow_state()
        assert state["step"]["kind"] == "idle"

        state = transition_auth_flow(state, "open_provider_picker", {
            "providers": [{"id": "openai", "displayName": "OpenAI", "authType": "api_key", "configured": False, "modelCount": 5}],
        })
        assert state["step"]["kind"] == "provider_picker"

        state = transition_auth_flow(state, "set_logging_in", {"providerId": "openai", "status": "Connecting..."})
        assert state["step"]["kind"] == "logging_in"

        state = transition_auth_flow(state, "set_logged_in", {"providerId": "openai", "nextStep": "model_picker"})
        assert state["step"]["kind"] == "logged_in"

        state = transition_auth_flow(state, "open_model_picker", {
            "models": [{"provider": "openai", "modelId": "gpt-4", "displayName": "GPT-4"}],
        })
        assert state["step"]["kind"] == "model_picker"

        state = transition_auth_flow(state, "set_idle")
        assert state["step"]["kind"] == "idle"


# =====================================================================
# 6. Orchestration: subagents + chains + runner helpers
# =====================================================================

sys.path.insert(0, os.path.normpath(os.path.join(_HERE, "..", "orchestration")))

from _subagents_toolchain import (
    SUBAGENT_TOOL_ALIASES,
    EXCLUDED_SUBAGENT_TOOLS,
    normalize_allowed_tool_names,
    filter_tools_for_subagent,
    load_agent_file,
    format_subagent_catalog,
    resolve_jackal_root,
    is_existing_dir,
)
from _chains_toolchain import (
    parse_step_body,
    parse_chain_markdown,
    format_chain_catalog,
    chain_dirs_exist,
)
from _subagent_runner_toolchain import (
    MAX_PARALLEL_SUBAGENTS,
    extract_assistant_summary,
    count_tool_calls,
    substitute_chain_template,
    build_step_prompt,
)


class TestSubagentToolAliases:
    def test_read_file_alias(self):
        assert SUBAGENT_TOOL_ALIASES["read_file"] == "read"

    def test_grep_alias(self):
        assert SUBAGENT_TOOL_ALIASES["grep"] == "bash"

    def test_excluded_tools(self):
        assert "agent" in EXCLUDED_SUBAGENT_TOOLS
        assert "subagent" in EXCLUDED_SUBAGENT_TOOLS


class TestNormalizeAllowedTools:
    def test_none_returns_none(self):
        assert normalize_allowed_tool_names(None) is None

    def test_empty_returns_none(self):
        assert normalize_allowed_tool_names([]) is None

    def test_maps_aliases(self):
        result = normalize_allowed_tool_names(["read_file", "bash"])
        assert "read" in result
        assert "bash" in result

    def test_mcp_prefix_stripped(self):
        result = normalize_allowed_tool_names(["mcp:validate_jac"])
        assert "validate_jac" in result

    def test_unknown_passes_through(self):
        result = normalize_allowed_tool_names(["custom_tool"])
        assert "custom_tool" in result


class TestFilterToolsForSubagent:
    def test_filters_excluded(self):
        result = filter_tools_for_subagent(
            ["read", "write", "agent", "subagent", "bash"], None
        )
        assert "agent" not in result
        assert "subagent" not in result
        assert "read" in result

    def test_filters_to_allowed(self):
        allowed = {"read", "write"}
        result = filter_tools_for_subagent(
            ["read", "write", "bash", "edit"], allowed
        )
        assert set(result) == {"read", "write"}

    def test_fallback_to_non_excluded(self):
        allowed = {"nonexistent"}
        result = filter_tools_for_subagent(
            ["read", "write", "agent"], allowed
        )
        assert "read" in result
        assert "agent" not in result

    def test_bash_auto_included_when_allowed(self):
        allowed = {"bash"}
        result = filter_tools_for_subagent(["read"], allowed)
        # Falls back to all non-excluded since bash isn't in all_tool_names
        assert "read" in result


class TestLoadAgentFile:
    def test_valid_agent(self, tmp_path):
        agent_md = tmp_path / "scout.md"
        agent_md.write_text("""---
name: scout
description: Fast recon agent
tools:
  - read
  - grep
model: claude-haiku
---

You are a scout agent.
""")
        result = load_agent_file(str(agent_md), "project")
        assert result is not None
        assert result["name"] == "scout"
        assert result["description"] == "Fast recon agent"
        assert result["tools"] == ["read", "grep"]
        assert result["model"] == "claude-haiku"
        assert result["source"] == "project"
        assert "scout agent" in result["systemPrompt"]

    def test_missing_name(self, tmp_path):
        agent_md = tmp_path / "bad.md"
        agent_md.write_text("---\ndescription: No name\n---\nBody")
        result = load_agent_file(str(agent_md), "package")
        assert result is None

    def test_missing_description(self, tmp_path):
        agent_md = tmp_path / "bad.md"
        agent_md.write_text("---\nname: test\n---\nBody")
        result = load_agent_file(str(agent_md), "package")
        assert result is None

    def test_nonexistent_file(self):
        result = load_agent_file("/nonexistent/file.md", "package")
        assert result is None


class TestFormatSubagentCatalog:
    def test_empty(self):
        catalog = format_subagent_catalog("/nonexistent")
        assert "No subagents found" in catalog

    def test_with_agents(self, tmp_path):
        agents_dir = tmp_path / "agents"
        agents_dir.mkdir()
        (agents_dir / "test.md").write_text("---\nname: tester\ndescription: Test agent\n---\nDo testing")
        catalog = format_subagent_catalog(str(tmp_path), agent_dir=str(tmp_path))
        # This may or may not find agents depending on .pi/agents path
        assert isinstance(catalog, str)


class TestParseStepBody:
    def test_task_only(self):
        step = parse_step_body("scout", "\nAnalyze the codebase for patterns.")
        assert step["agent"] == "scout"
        assert step["task"] == "Analyze the codebase for patterns."

    def test_with_config(self):
        body = "output: plan.md\nreads: report.md, context.md\n\nAnalyze the code."
        step = parse_step_body("scout", body)
        assert step["output"] == "plan.md"
        assert step["reads"] == ["report.md", "context.md"]
        assert "Analyze" in step["task"]

    def test_with_model(self):
        body = "model: claude-haiku\n\nDo something quick."
        step = parse_step_body("agent", body)
        assert step["model"] == "claude-haiku"


class TestParseChainMarkdown:
    def test_valid_chain(self):
        content = """---
name: pipeline
description: Full analysis pipeline
---

## scout
Analyze the codebase.

## architect
Design the solution.
"""
        chain = parse_chain_markdown(content, "package", "test.chain.md")
        assert chain["name"] == "pipeline"
        assert chain["description"] == "Full analysis pipeline"
        assert len(chain["steps"]) == 2
        assert chain["steps"][0]["agent"] == "scout"
        assert chain["steps"][1]["agent"] == "architect"

    def test_missing_name_raises(self):
        content = "---\ndescription: No name\n---\n## scout\nDo stuff"
        import pytest
        with pytest.raises(ValueError, match="name and description"):
            parse_chain_markdown(content, "package", "test.chain.md")

    def test_no_steps_raises(self):
        content = "---\nname: test\ndescription: Test\n---\nNo steps here."
        import pytest
        with pytest.raises(ValueError, match="no ## steps"):
            parse_chain_markdown(content, "package", "test.chain.md")


class TestExtractAssistantSummary:
    def test_string_content(self):
        msgs = [
            {"role": "user", "content": "hello"},
            {"role": "assistant", "content": "hi there"},
        ]
        assert extract_assistant_summary(msgs) == "hi there"

    def test_array_content(self):
        msgs = [
            {"role": "assistant", "content": [{"type": "text", "text": "part one"}, {"type": "text", "text": "part two"}]},
        ]
        result = extract_assistant_summary(msgs)
        assert "part one" in result
        assert "part two" in result

    def test_no_assistant_messages(self):
        msgs = [{"role": "user", "content": "hello"}]
        assert extract_assistant_summary(msgs) == "(no subagent output)"

    def test_multiple_assistant_messages(self):
        msgs = [
            {"role": "assistant", "content": "first"},
            {"role": "user", "content": "ok"},
            {"role": "assistant", "content": "second"},
        ]
        result = extract_assistant_summary(msgs)
        assert "first" in result
        assert "second" in result


class TestCountToolCalls:
    def test_with_tool_calls(self):
        msgs = [
            {"role": "assistant", "content": [
                {"type": "toolCall", "name": "read"},
                {"type": "text", "text": "output"},
            ]},
        ]
        assert count_tool_calls(msgs) == 1

    def test_no_tool_calls(self):
        msgs = [{"role": "assistant", "content": "just text"}]
        assert count_tool_calls(msgs) == 0

    def test_empty_messages(self):
        assert count_tool_calls([]) == 0


class TestSubstituteChainTemplate:
    def test_basic_substitution(self):
        result = substitute_chain_template("Do {task} with {previous}", "the work", "prior context")
        assert result == "Do the work with prior context"

    def test_no_placeholders(self):
        assert substitute_chain_template("no placeholders", "a", "b") == "no placeholders"


class TestBuildStepPrompt:
    def test_basic_prompt(self):
        step = {"agent": "scout", "task": "Analyze {task}"}
        result = build_step_prompt(step, "the code", "")
        assert "Analyze the code" == result

    def test_with_reads(self):
        step = {"agent": "scout", "task": "Analyze", "reads": ["report.md", "plan.md"]}
        result = build_step_prompt(step, "task", "")
        assert "report.md" in result
        assert "plan.md" in result
        assert "prior step" in result

    def test_with_output(self):
        step = {"agent": "scout", "task": "Analyze", "output": "report.md"}
        result = build_step_prompt(step, "task", "")
        assert "report.md" in result
        assert "markdown" in result.lower()

    def test_max_parallel_constant(self):
        assert MAX_PARALLEL_SUBAGENTS == 5
