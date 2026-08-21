"""Tests for Phase 4 Python toolchain modules.

Tests all new modules ported from:
- src/agent/tools.ts → _path_resolve_toolchain.py
- src/agent/mcp-schema.ts → _mcp_schema_coerce_toolchain.py (covered by existing _mcp_schema_toolchain tests)
- src/core/adapter.ts → _adapter_helpers_toolchain.py
- src/core/agent-busy.ts → _agent_busy_toolchain.py
- src/core/store.ts + bridge.ts → _store_types_toolchain.py
- src/session/llm-compact.ts → _llm_compact_toolchain.py
- src/session/outbound-queue.ts → _outbound_queue_toolchain.py
"""

import os
import sys
import json
import tempfile

# Ensure lib/jac dirs are on sys.path
_LIB = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))
for _sub in ("agent", "core", "session", "jac", "auth", "config"):
    _p = os.path.join(_LIB, _sub)
    if _p not in sys.path:
        sys.path.insert(0, _p)


# ─── Path resolve ────────────────────────────────────────────────────────────

class TestSafeResolve:
    def test_relative_path(self, tmp_path):
        from _path_resolve_toolchain import safe_resolve
        result = safe_resolve(str(tmp_path), "src/main.ts")
        assert result == os.path.normpath(os.path.join(str(tmp_path), "src/main.ts"))

    def test_absolute_within_cwd(self, tmp_path):
        from _path_resolve_toolchain import safe_resolve
        target = os.path.join(str(tmp_path), "a.ts")
        result = safe_resolve(str(tmp_path), target)
        assert result == os.path.normpath(target)

    def test_escape_throws(self, tmp_path):
        from _path_resolve_toolchain import safe_resolve
        import pytest
        with pytest.raises(ValueError, match="escapes cwd"):
            safe_resolve(str(tmp_path), "../../etc/passwd")

    def test_dotdot_in_middle(self, tmp_path):
        from _path_resolve_toolchain import safe_resolve
        import pytest
        with pytest.raises(ValueError, match="escapes cwd"):
            safe_resolve(str(tmp_path), "foo/../../../etc/passwd")


class TestResolveReadPath:
    def test_cwd_relative(self, tmp_path):
        from _path_resolve_toolchain import resolve_read_path
        result = resolve_read_path(str(tmp_path), "src/main.ts")
        assert result == os.path.normpath(os.path.join(str(tmp_path), "src/main.ts"))

    def test_allow_file(self, tmp_path):
        from _path_resolve_toolchain import resolve_read_path
        outside = "/tmp/outside.ts"
        result = resolve_read_path(str(tmp_path), outside, allow_files={outside})
        assert result == outside

    def test_allow_root(self, tmp_path):
        from _path_resolve_toolchain import resolve_read_path
        skill_root = "/opt/skills"
        target = "/opt/skills/search/SKILL.md"
        result = resolve_read_path(str(tmp_path), target, allow_roots={skill_root + "/"})
        assert result == target

    def test_escape_throws(self, tmp_path):
        from _path_resolve_toolchain import resolve_read_path
        import pytest
        with pytest.raises(ValueError, match="escapes cwd"):
            resolve_read_path(str(tmp_path), "/etc/passwd")


class TestFormatPostWriteMessage:
    def test_no_notes(self):
        from _path_resolve_toolchain import format_post_write_message
        assert format_post_write_message("Wrote", "foo.ts") == "Wrote foo.ts"

    def test_with_notes(self):
        from _path_resolve_toolchain import format_post_write_message
        result = format_post_write_message("Edited", "bar.jac", ["note1", "note2"])
        assert "Edited bar.jac" in result
        assert "note1" in result
        assert "note2" in result

    def test_empty_notes(self):
        from _path_resolve_toolchain import format_post_write_message
        assert format_post_write_message("Wrote", "x.ts", []) == "Wrote x.ts"


# ─── Adapter helpers ────────────────────────────────────────────────────────

class TestResolveContextMax:
    def test_explicit_option(self):
        from _adapter_helpers_toolchain import resolve_context_max
        assert resolve_context_max("/tmp", options={"contextMax": 8000}) == 8000

    def test_env_value(self):
        from _adapter_helpers_toolchain import resolve_context_max
        assert resolve_context_max("/tmp", env_value="16000") == 16000

    def test_project_config(self):
        from _adapter_helpers_toolchain import resolve_context_max
        assert resolve_context_max("/tmp", project_config={"contextMax": 32000}) == 32000

    def test_priority_explicit_over_env(self):
        from _adapter_helpers_toolchain import resolve_context_max
        assert resolve_context_max("/tmp", options={"contextMax": 4000}, env_value="9999") == 4000

    def test_none_when_unset(self):
        from _adapter_helpers_toolchain import resolve_context_max
        assert resolve_context_max("/tmp") is None

    def test_zero_returns_none(self):
        from _adapter_helpers_toolchain import resolve_context_max
        assert resolve_context_max("/tmp", options={"contextMax": 0}) is None

    def test_negative_returns_none(self):
        from _adapter_helpers_toolchain import resolve_context_max
        assert resolve_context_max("/tmp", options={"contextMax": -1}) is None

    def test_invalid_env(self):
        from _adapter_helpers_toolchain import resolve_context_max
        assert resolve_context_max("/tmp", env_value="notanumber") is None


class TestSessionStorageDir:
    def test_default(self, tmp_path):
        from _adapter_helpers_toolchain import session_storage_dir
        result = session_storage_dir(str(tmp_path))
        assert result == os.path.join(str(tmp_path), ".jackal", "sessions")

    def test_override(self, tmp_path):
        from _adapter_helpers_toolchain import session_storage_dir
        result = session_storage_dir(str(tmp_path), "/custom/path")
        assert result == "/custom/path"


# ─── Agent busy ──────────────────────────────────────────────────────────────

class TestIsAgentBusy:
    def test_streaming(self):
        from _agent_busy_toolchain import is_agent_busy
        assert is_agent_busy({"phase": "streaming"}) is True

    def test_compacting(self):
        from _agent_busy_toolchain import is_agent_busy
        assert is_agent_busy({"phase": "compacting"}) is True

    def test_retrying(self):
        from _agent_busy_toolchain import is_agent_busy
        assert is_agent_busy({"phase": "retrying"}) is True

    def test_ready(self):
        from _agent_busy_toolchain import is_agent_busy
        assert is_agent_busy({"phase": "ready"}) is False

    def test_booting(self):
        from _agent_busy_toolchain import is_agent_busy
        assert is_agent_busy({"phase": "booting"}) is False

    def test_live_tool_call(self):
        from _agent_busy_toolchain import is_agent_busy
        assert is_agent_busy({"phase": "ready", "liveToolCallId": "tc_1"}) is True

    def test_running_tool_execution(self):
        from _agent_busy_toolchain import is_agent_busy
        snap = {
            "phase": "ready",
            "toolExecutions": {
                "tc_1": {"status": "running"},
                "tc_2": {"status": "done"},
            }
        }
        assert is_agent_busy(snap) is True

    def test_all_done(self):
        from _agent_busy_toolchain import is_agent_busy
        snap = {
            "phase": "ready",
            "toolExecutions": {"tc_1": {"status": "done"}}
        }
        assert is_agent_busy(snap) is False


# ─── Store types / bridge helpers ────────────────────────────────────────────

class TestStoreConstants:
    def test_agent_phases(self):
        from _store_types_toolchain import AGENT_PHASES
        assert AGENT_PHASES == ["booting", "ready", "streaming", "compacting", "retrying", "error"]

    def test_max_tool_executions(self):
        from _store_types_toolchain import MAX_TOOL_EXECUTIONS
        assert MAX_TOOL_EXECUTIONS == 40

    def test_stream_emit_ms(self):
        from _store_types_toolchain import STREAM_EMIT_MS
        assert STREAM_EMIT_MS == 32

    def test_initial_snapshot_keys(self):
        from _store_types_toolchain import INITIAL_SNAPSHOT
        assert "phase" in INITIAL_SNAPSHOT
        assert INITIAL_SNAPSHOT["phase"] == "booting"
        assert INITIAL_SNAPSHOT["mode"] == "normal"
        assert INITIAL_SNAPSHOT["messages"] == []
        assert INITIAL_SNAPSHOT["transcript"] == []


class TestAgentMessagesToTranscript:
    def test_basic(self):
        from _store_types_toolchain import agent_messages_to_transcript
        msgs = [
            {"role": "user", "text": "hello"},
            {"role": "assistant", "text": "hi there"},
            {"role": "system", "text": "ready"},
        ]
        result = agent_messages_to_transcript(msgs)
        assert len(result) == 3
        assert result[0] == {"kind": "user", "text": "hello"}
        assert result[1] == {"kind": "assistant", "text": "hi there"}
        assert result[2] == {"kind": "system", "text": "ready"}

    def test_empty(self):
        from _store_types_toolchain import agent_messages_to_transcript
        assert agent_messages_to_transcript([]) == []


class TestToolResultDisplayText:
    def test_string(self):
        from _store_types_toolchain import tool_result_display_text
        assert tool_result_display_text("hello") == "hello"

    def test_none(self):
        from _store_types_toolchain import tool_result_display_text
        assert tool_result_display_text(None) is None

    def test_error_dict(self):
        from _store_types_toolchain import tool_result_display_text
        assert tool_result_display_text({"error": "bad"}) == "bad"

    def test_content_array(self):
        from _store_types_toolchain import tool_result_display_text
        val = {"content": [{"type": "text", "text": "line1"}, {"type": "text", "text": "line2"}]}
        assert tool_result_display_text(val) == "line1\nline2"

    def test_unknown_type(self):
        from _store_types_toolchain import tool_result_display_text
        assert tool_result_display_text(42) is None


class TestFormatToolPayload:
    def test_truncates_string(self):
        from _store_types_toolchain import format_tool_payload
        result = format_tool_payload("short")
        assert result == "short"

    def test_none_returns_none(self):
        from _store_types_toolchain import format_tool_payload
        # None value has no display text, and truncating None also yields None
        result = format_tool_payload(None)
        assert result is None


class TestToolResultStatus:
    def test_done(self):
        from _store_types_toolchain import tool_result_status
        assert tool_result_status("ok") == "done"

    def test_error_flag(self):
        from _store_types_toolchain import tool_result_status
        assert tool_result_status("ok", is_error=True) == "error"

    def test_error_in_dict(self):
        from _store_types_toolchain import tool_result_status
        assert tool_result_status({"error": "x"}) == "error"


class TestAgentMessageToStore:
    def test_string_content(self):
        from _store_types_toolchain import agent_message_to_store
        result = agent_message_to_store({"role": "user", "content": "hello"})
        assert result == {"role": "user", "text": "hello"}

    def test_array_content(self):
        from _store_types_toolchain import agent_message_to_store
        result = agent_message_to_store({
            "role": "assistant",
            "content": [{"type": "text", "text": "hi"}],
        })
        assert result == {"role": "assistant", "text": "hi"}

    def test_unknown_role(self):
        from _store_types_toolchain import agent_message_to_store
        assert agent_message_to_store({"role": "tool", "content": "x"}) is None

    def test_none_content(self):
        from _store_types_toolchain import agent_message_to_store
        result = agent_message_to_store({"role": "user", "content": None})
        assert result == {"role": "user", "text": ""}


class TestAgentMessagesToStore:
    def test_filters_non_dicts(self):
        from _store_types_toolchain import agent_messages_to_store
        result = agent_messages_to_store([None, "bad", {"role": "user", "content": "ok"}])
        assert len(result) == 1
        assert result[0]["text"] == "ok"


class TestBuildSeedData:
    def test_basic(self):
        from _store_types_toolchain import build_seed_data
        result = build_seed_data("normal", "openai", "gpt-4", "sess1", "Test")
        assert result["mode"] == "normal"
        assert result["provider"] == "openai"
        assert result["model"] == "gpt-4"
        assert "messages" not in result

    def test_with_messages(self):
        from _store_types_toolchain import build_seed_data
        msgs = [{"role": "user", "content": "hi"}, {"role": "assistant", "content": "hello"}]
        result = build_seed_data("normal", "p", "m", "s", "n", msgs)
        assert len(result["messages"]) == 2
        assert len(result["transcript"]) == 2


# ─── LLM compact ────────────────────────────────────────────────────────────

class TestWrapCompactionSummary:
    def test_basic(self):
        from _llm_compact_toolchain import wrap_compaction_summary
        result = wrap_compaction_summary("Summary of talk here.")
        assert "<conversation-summary>" in result
        assert "Summary of talk here." in result
        assert "</conversation-summary>" in result
        assert "automated summary" in result

    def test_empty(self):
        from _llm_compact_toolchain import wrap_compaction_summary
        assert wrap_compaction_summary("") == ""
        assert wrap_compaction_summary("   ") == ""

    def test_whitespace_trimmed(self):
        from _llm_compact_toolchain import wrap_compaction_summary
        result = wrap_compaction_summary("  stuff  ")
        assert result.startswith("<conversation-summary>\nstuff\n</conversation-summary>")


# ─── Outbound queue ──────────────────────────────────────────────────────────

class TestOutboundQueue:
    def test_enqueue_dequeue(self):
        from _outbound_queue_toolchain import OutboundMessageQueue
        q = OutboundMessageQueue()
        q.enqueue("first")
        q.enqueue("second")
        assert q.length == 2
        assert q.dequeue() == "first"
        assert q.dequeue() == "second"
        assert q.dequeue() is None

    def test_peek_is_copy(self):
        from _outbound_queue_toolchain import OutboundMessageQueue
        q = OutboundMessageQueue()
        q.enqueue("a")
        peeked = q.peek()
        assert peeked == ["a"]
        peeked.append("b")
        assert q.peek() == ["a"]

    def test_empty_string_ignored(self):
        from _outbound_queue_toolchain import OutboundMessageQueue
        q = OutboundMessageQueue()
        q.enqueue("")
        q.enqueue("   ")
        assert q.length == 0

    def test_clear(self):
        from _outbound_queue_toolchain import OutboundMessageQueue
        q = OutboundMessageQueue()
        q.enqueue("x")
        q.enqueue("y")
        q.clear()
        assert q.length == 0
        assert q.peek() == []

    def test_trimmed(self):
        from _outbound_queue_toolchain import OutboundMessageQueue
        q = OutboundMessageQueue()
        q.enqueue("  hello  ")
        assert q.dequeue() == "hello"

    def test_to_dict_roundtrip(self):
        from _outbound_queue_toolchain import OutboundMessageQueue
        q = OutboundMessageQueue()
        q.enqueue("a")
        q.enqueue("b")
        d = q.to_dict()
        q2 = OutboundMessageQueue.from_dict(d)
        assert q2.peek() == ["a", "b"]
        assert q2.length == 2


class TestResolveAuthPath:
    def test_explicit_agent_dir(self):
        from _auth_io_toolchain import resolve_auth_path
        result = resolve_auth_path("/opt/jackal")
        assert result == "/opt/jackal/auth.json"

    def test_env_override(self, monkeypatch):
        from _auth_io_toolchain import resolve_auth_path
        monkeypatch.setenv("JACKAL_AGENT_DIR", "/env/path")
        result = resolve_auth_path()
        assert result == "/env/path/auth.json"

    def test_default_home(self, monkeypatch):
        from _auth_io_toolchain import resolve_auth_path
        monkeypatch.delenv("JACKAL_AGENT_DIR", raising=False)
        result = resolve_auth_path()
        assert result.endswith(".jackal/auth.json")


class TestLoadAuthFile:
    def test_missing_file(self, tmp_path):
        from _auth_io_toolchain import load_auth_file
        result = load_auth_file(str(tmp_path / "nonexistent.json"))
        assert result == {}

    def test_valid_file(self, tmp_path):
        from _auth_io_toolchain import load_auth_file
        p = tmp_path / "auth.json"
        p.write_text('{"openai": {"type": "api_key", "key": "sk-123"}}')
        result = load_auth_file(str(p))
        assert "openai" in result
        assert result["openai"]["key"] == "sk-123"

    def test_invalid_json(self, tmp_path):
        from _auth_io_toolchain import load_auth_file
        p = tmp_path / "auth.json"
        p.write_text("not json")
        result = load_auth_file(str(p))
        assert result == {}

    def test_non_dict_json(self, tmp_path):
        from _auth_io_toolchain import load_auth_file
        p = tmp_path / "auth.json"
        p.write_text("[1, 2, 3]")
        result = load_auth_file(str(p))
        assert result == {}


class TestSaveAuthFile:
    def test_creates_dir_and_file(self, tmp_path):
        from _auth_io_toolchain import load_auth_file, save_auth_file
        p = tmp_path / "sub" / "dir" / "auth.json"
        data = {"openai": {"type": "api_key", "key": "sk-test"}}
        save_auth_file(str(p), data)
        assert p.is_file()
        loaded = load_auth_file(str(p))
        assert loaded == data

    def test_overwrites(self, tmp_path):
        from _auth_io_toolchain import load_auth_file, save_auth_file
        p = tmp_path / "auth.json"
        save_auth_file(str(p), {"a": 1})
        save_auth_file(str(p), {"b": 2})
        loaded = load_auth_file(str(p))
        assert "a" not in loaded
        assert loaded["b"] == 2


class TestGetAuthStatus:
    def test_runtime_key(self):
        from _auth_io_toolchain import get_auth_status
        result = get_auth_status("openai", {}, runtime_keys={"openai"})
        assert result["configured"] is True
        assert result["source"] == "stored"
        assert result["label"] == "runtime override"

    def test_stored(self):
        from _auth_io_toolchain import get_auth_status
        result = get_auth_status("openai", {"openai": {"type": "api_key", "key": "sk-..."}})
        assert result["configured"] is True
        assert result["source"] == "stored"

    def test_env(self):
        from _auth_io_toolchain import get_auth_status
        result = get_auth_status("openai", {}, env_api_key="sk-env-key")
        assert result["configured"] is True
        assert result["source"] == "environment"

    def test_not_configured(self):
        from _auth_io_toolchain import get_auth_status
        result = get_auth_status("openai", {})
        assert result["configured"] is False


# ─── Boot batch ──────────────────────────────────────────────────────────────

class TestBootBatch:
    def test_returns_config_and_mode(self):
        from _project_config_toolchain import boot_batch
        result = boot_batch(os.getcwd())
        assert "projectConfig" in result
        assert "bootMode" in result
        assert result["bootMode"] in ("normal", "auto-accept", "yolo", "plan", "ask")

    def test_context_max_default_none(self):
        from _project_config_toolchain import boot_batch
        result = boot_batch("/tmp")
        assert result["contextMax"] is None
