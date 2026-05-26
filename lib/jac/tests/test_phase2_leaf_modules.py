"""Tests for frontmatter, file mention parser, context usage, tasks, custom commands, dev mode, overlay rows."""

import json
import os
import tempfile
from pathlib import Path

import sys

# Add dirs to path
for _subdir in ("orchestration", "workflow", "agent", "ui", "config"):
    _pkg = os.path.join(os.path.dirname(__file__), "..", _subdir)
    if _pkg not in sys.path:
        sys.path.insert(0, _pkg)

from _frontmatter_toolchain import (
    parse_frontmatter,
    frontmatter_string,
    frontmatter_string_list,
)
from _file_mention_parser_toolchain import (
    parse_file_mentions,
    parse_line_range,
    is_valid_file_path,
    parse_mention_token,
    get_current_file_mention,
)
from _context_usage_toolchain import (
    estimate_tokens,
    estimate_messages_tokens,
    get_context_max,
    compute_context_usage,
    format_usage_line,
)
from _tasks_toolchain import (
    generate_task_id,
    load_tasks,
    save_tasks,
    add_task,
    update_tasks,
    task_counts,
    format_task_line,
    format_tasks_list,
)
from _custom_commands_toolchain import (
    load_custom_commands,
    expand_command_template,
    resolve_custom_command_input,
    custom_command_slash_names,
)
from _dev_mode_toolchain import (
    is_read_only_mode,
    is_tool_blocked_in_read_only_mode,
    cycle_mode,
    is_destructive_bash,
    should_auto_approve,
    system_prompt_for_mode,
)
from _system_prompt_toolchain import load_system_prompt_base
from _tool_output_limit_toolchain import (
    MAX_TOOL_OUTPUT_BYTES,
    truncate_tool_output,
    truncate_tool_payload,
)
from _skill_commands_toolchain import format_skill_command_catalog
from _session_permissions_toolchain import (
    match_pattern as _match_pattern,
    evaluate_permission_patterns as _eval_patterns,
    load_permission_patterns as _load_patterns,
    needs_tool_approval as _needs_approval,
)
from _approval_display_toolchain import format_approval_display as _format_approval
from _context_input_toolchain import (
    _safe_resolve,
    expand_context_input_sync,
)
from _overlay_rows_toolchain import (
    task_status_icon,
    format_task_overlay_row,
    format_tasks_overlay_header,
)


# --- Frontmatter tests ---

def test_parse_frontmatter_no_frontmatter():
    result = parse_frontmatter("Hello world")
    assert result.frontmatter == {}
    assert result.body == "Hello world"


def test_parse_frontmatter_with_block():
    content = "---\ntitle: Test\ndescription: A test file\n---\nBody text"
    result = parse_frontmatter(content)
    assert result.frontmatter["title"] == "Test"
    assert result.frontmatter["description"] == "A test file"
    assert result.body == "Body text"


def test_parse_frontmatter_list_values():
    content = "---\ntitle: Test\naliases:\n  - foo\n  - bar\n---\nBody"
    result = parse_frontmatter(content)
    assert result.frontmatter["aliases"] == ["foo", "bar"]


def test_frontmatter_string():
    assert frontmatter_string(None) is None
    assert frontmatter_string("hello") == "hello"
    assert frontmatter_string(["a", "b"]) == "a, b"


def test_frontmatter_string_list():
    assert frontmatter_string_list(None) == []
    assert frontmatter_string_list("a, b, c") == ["a", "b", "c"]
    assert frontmatter_string_list(["x", "y"]) == ["x", "y"]


# --- File mention parser tests ---

def test_parse_file_mentions_basic():
    mentions = parse_file_mentions("look at @src/index.ts")
    assert len(mentions) == 1
    assert mentions[0].file_path == "src/index.ts"


def test_parse_file_mentions_line_range():
    mentions = parse_file_mentions("@src/index.ts:10-20")
    assert len(mentions) == 1
    assert mentions[0].file_path == "src/index.ts"
    assert mentions[0].line_range == {"start": 10, "end": 20}


def test_is_valid_file_path():
    assert is_valid_file_path("src/index.ts")
    assert not is_valid_file_path("")
    assert not is_valid_file_path("../etc/passwd")
    assert not is_valid_file_path("/etc/passwd")


def test_parse_line_range():
    assert parse_line_range("10") == {"start": 10}
    assert parse_line_range("10-20") == {"start": 10, "end": 20}
    assert parse_line_range("") is None
    assert parse_line_range("abc") is None


def test_parse_mention_token():
    assert parse_mention_token("src/foo.ts") == {"path": "src/foo.ts"}
    result = parse_mention_token("src/foo.ts:10")
    assert result["path"] == "src/foo.ts"
    assert result["startLine"] == 10


def test_get_current_file_mention():
    result = get_current_file_mention("look at @src/ind", 15)
    assert result is not None
    assert result["mention"].startswith("src/ind")


# --- Context usage tests ---

def test_estimate_tokens():
    assert estimate_tokens("") == 0
    assert estimate_tokens("hello") == 2  # 5 chars / 4


def test_estimate_messages_tokens():
    msgs = [{"content": "hello world"}]
    tokens = estimate_messages_tokens(msgs)
    assert tokens > 0


def test_get_context_max():
    assert get_context_max() == 128000
    assert get_context_max(override=50000) == 50000
    assert get_context_max(context_window=200000) == 200000


def test_compute_context_usage():
    result = compute_context_usage(
        [{"content": "hello"}], system_prompt="You are helpful."
    )
    assert "used" in result
    assert "max" in result
    assert "percent" in result
    assert result["percent"] >= 0


def test_format_usage_line():
    usage = {"used": 1000, "max": 128000, "percent": 1}
    line = format_usage_line(usage)
    assert "1,000" in line
    assert "128,000" in line


# --- Tasks tests ---

def test_generate_task_id():
    tid = generate_task_id()
    assert len(tid) == 8


def test_tasks_roundtrip():
    with tempfile.TemporaryDirectory() as tmp:
        task = add_task(tmp, "Test task", "A description")
        assert task["title"] == "Test task"
        assert task["status"] == "pending"

        loaded = load_tasks(tmp)
        assert len(loaded) == 1
        assert loaded[0]["id"] == task["id"]


def test_update_tasks():
    with tempfile.TemporaryDirectory() as tmp:
        task = add_task(tmp, "Test")
        updated = update_tasks(tmp, [{"id": task["id"], "status": "completed"}])
        assert updated[0]["status"] == "completed"


def test_task_counts():
    tasks = [
        {"id": "a", "title": "t", "status": "pending", "createdAt": "", "updatedAt": ""},
        {"id": "b", "title": "t", "status": "completed", "createdAt": "", "updatedAt": ""},
    ]
    counts = task_counts(tasks)
    assert counts["pending"] == 1
    assert counts["completed"] == 1


def test_format_task_line():
    task = {"id": "abc", "title": "My task", "status": "pending", "createdAt": "", "updatedAt": ""}
    line = format_task_line(task)
    assert "My task" in line
    assert "abc" in line


def test_format_tasks_list_empty():
    assert "No tasks" in format_tasks_list([])


# --- Custom commands tests ---

def test_load_custom_commands_empty():
    with tempfile.TemporaryDirectory() as tmp:
        cmds = load_custom_commands(tmp)
        assert cmds == []


def test_expand_command_template():
    result = expand_command_template(
        "Review {{cwd}}/{{args}}", "review", ["src/main.ts"], [], "/tmp/project"
    )
    assert "/tmp/project" in result
    assert "src/main.ts" in result


def test_resolve_custom_command_input():
    cmds = [{"name": "review", "aliases": ["r"], "parameters": [], "body": "Review"}]
    result = resolve_custom_command_input("/review src/main.ts", cmds)
    assert result is not None
    assert result["command"]["name"] == "review"
    assert result["args"] == ["src/main.ts"]


# --- Dev mode tests ---

def test_is_read_only_mode():
    assert is_read_only_mode("plan")
    assert is_read_only_mode("ask")
    assert not is_read_only_mode("normal")
    assert not is_read_only_mode("yolo")


def test_is_tool_blocked():
    assert is_tool_blocked_in_read_only_mode("write")
    assert is_tool_blocked_in_read_only_mode("edit")
    assert not is_tool_blocked_in_read_only_mode("read")
    assert not is_tool_blocked_in_read_only_mode("bash")


def test_cycle_mode():
    assert cycle_mode("normal") == "auto-accept"
    assert cycle_mode("ask") == "normal"


def test_is_destructive_bash():
    assert is_destructive_bash("rm -rf /")
    assert is_destructive_bash("git push --force")
    assert not is_destructive_bash("ls -la")
    assert not is_destructive_bash("git status")


def test_should_auto_approve():
    assert should_auto_approve("yolo", "write", {})
    assert should_auto_approve("auto-accept", "write", {})
    assert not should_auto_approve("normal", "write", {})
    assert should_auto_approve("plan", "read", {})
    assert not should_auto_approve("plan", "write", {})


def test_system_prompt_for_mode():
    result = system_prompt_for_mode("You are helpful.", "plan")
    assert "Plan mode (active)" in result
    result2 = system_prompt_for_mode("You are helpful.", "normal")
    assert "Plan mode" not in result2


def test_load_system_prompt_base_fallback():
    with tempfile.TemporaryDirectory() as tmp:
        text = load_system_prompt_base(tmp)
        assert "You are Jackal" in text


def test_tool_output_truncate_utf8_safe():
    out = truncate_tool_output("😀" * 20000)
    assert len(out.encode("utf-8")) <= MAX_TOOL_OUTPUT_BYTES


def test_tool_output_truncate_payload_error_field():
    assert truncate_tool_payload({"error": "boom"}) == "boom"


def test_format_skill_command_catalog_empty():
    text = format_skill_command_catalog([])
    assert "No skills found." in text


# --- Session permissions tests ---


def test_match_pattern_glob():
    assert _match_pattern("src/main.ts", "*.ts")
    assert not _match_pattern("src/main.ts", "*.py")


def test_match_pattern_exact():
    assert _match_pattern("hello", "hello", "exact")
    assert not _match_pattern("hello", "hell", "exact")


def test_match_pattern_prefix():
    assert _match_pattern("src/main.ts", "src/", "prefix")
    assert not _match_pattern("src/main.ts", "lib/", "prefix")


def test_match_pattern_regex():
    assert _match_pattern("src/main.ts", r"\.ts$", "regex")
    assert not _match_pattern("src/main.py", r"\.ts$", "regex")


def test_evaluate_permission_patterns_deny():
    patterns = [{"tool": "bash", "pattern": "rm -rf /", "type": "exact", "action": "deny"}]
    assert _eval_patterns(patterns, "bash", "rm -rf /") == "deny"


def test_evaluate_permission_patterns_allow():
    patterns = [{"tool": "read", "pattern": "*", "type": "glob", "action": "allow"}]
    assert _eval_patterns(patterns, "read", "anything") == "allow"


def test_load_permission_patterns():
    cfg = {"permissionPatterns": [{"tool": "bash", "pattern": "echo *"}]}
    result = _load_patterns(cfg)
    assert len(result) == 1
    assert result[0]["type"] == "glob"  # default


def test_needs_tool_approval_normal():
    assert _needs_approval("normal", "bash", {"command": "ls"})


def test_needs_tool_approval_auto_accept():
    assert not _needs_approval("auto-accept", "bash", {"command": "ls"})


def test_needs_tool_approval_yolo():
    assert not _needs_approval("yolo", "bash", {"command": "rm -rf /tmp/x"})


# --- Approval display tests ---


def test_format_approval_bash():
    result = _format_approval("bash", {"command": "echo hello"})
    assert result["headline"] == "bash — shell command"
    assert "echo hello" in " ".join(l["text"] for l in result["previewLines"])


def test_format_approval_edit():
    result = _format_approval("edit", {
        "path": "src/main.ts",
        "edits": [{"oldText": "old", "newText": "new"}],
    })
    assert result["headline"] == "edit — src/main.ts"
    tones = [l["tone"] for l in result["previewLines"]]
    assert "removed" in tones
    assert "added" in tones


def test_format_approval_subagent():
    result = _format_approval("bash", {"command": "ls"}, subagent_name="scout")
    assert "scout" in result["headline"] or "scout" in " ".join(result["detailLines"])


# --- Context input tests ---


def test_safe_resolve_normal():
    with tempfile.TemporaryDirectory() as tmp:
        resolved = _safe_resolve(tmp, "foo.txt")
        assert resolved.endswith("foo.txt")


def test_safe_resolve_escape():
    with tempfile.TemporaryDirectory() as tmp:
        try:
            _safe_resolve(tmp, "../../etc/passwd")
            assert False, "Should have raised"
        except ValueError:
            pass


def test_expand_context_plain():
    with tempfile.TemporaryDirectory() as tmp:
        result = expand_context_input_sync(tmp, "hello world")
        assert result["result"] == "hello world"


def test_expand_context_command():
    with tempfile.TemporaryDirectory() as tmp:
        result = expand_context_input_sync(tmp, "!echo hello")
        assert "hello" in result["result"]


def test_expand_context_file_mention():
    with tempfile.TemporaryDirectory() as tmp:
        # Create a file to mention
        Path(os.path.join(tmp, "test.txt")).write_text("hello from file")
        result = expand_context_input_sync(tmp, "@test.txt what do you think?")
        assert "hello from file" in result["result"]
        assert "<file" in result["result"]


# --- Overlay rows tests ---

def test_task_status_icon():
    assert task_status_icon("pending") == "○"
    assert task_status_icon("in_progress") == "◐"
    assert task_status_icon("completed") == "✓"


def test_format_task_overlay_row():
    task = {"title": "Fix bug", "status": "pending", "description": "Critical"}
    row = format_task_overlay_row(task, 0)
    assert "Fix bug" in row
    assert "Critical" in row


def test_format_tasks_overlay_header():
    tasks = [
        {"title": "t", "status": "pending"},
        {"title": "t", "status": "completed"},
    ]
    header = format_tasks_overlay_header(tasks)
    assert "2 task(s)" in header
