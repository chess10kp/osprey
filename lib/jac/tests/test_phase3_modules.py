"""Tests for skills, project-init, mcp-schema, task-tools, and web-tools toolchain modules."""

import json
import os
import tempfile
from pathlib import Path

import sys

# Add dirs to path
for _subdir in ("project", "agent", "orchestration", "workflow"):
    _pkg = os.path.join(os.path.dirname(__file__), "..", _subdir)
    if _pkg not in sys.path:
        sys.path.insert(0, _pkg)

from _skills_toolchain import (
    load_skills_from_dir,
    load_jackal_skills,
    format_skills_for_prompt,
    append_skills_to_prompt,
    expand_skill_command,
    load_skill_by_dir,
    skill_read_allowlist,
    _validate_name,
    _validate_description,
)
from _project_init_toolchain import (
    analyze_project,
    generate_agents_md,
    run_project_init,
    _parse_jac_toml,
    _classify_project,
)
from _mcp_schema_toolchain import (
    mcp_input_schema_to_parameters,
    coerce_by_schema,
    validate_and_coerce_args,
)
from _task_tools_toolchain import (
    validate_create_tasks,
    validate_update_tasks,
    validate_delete_tasks,
    build_create_result,
    build_list_result,
    build_delete_result,
)
from _web_tools_toolchain import (
    assert_safe_fetch_url,
    html_to_readable_text,
    format_web_search_results,
    parse_brave_search_response,
)


# =============================================================================
# Skills tests
# =============================================================================

def test_validate_name_valid():
    assert _validate_name("my-skill") == []
    assert _validate_name("abc123") == []


def test_validate_name_too_long():
    errors = _validate_name("a" * 65)
    assert any("exceeds" in e for e in errors)


def test_validate_name_invalid_chars():
    errors = _validate_name("My_Skill")
    assert any("invalid characters" in e for e in errors)


def test_validate_name_hyphen_edges():
    assert any("hyphen" in e for e in _validate_name("-start"))
    assert any("hyphen" in e for e in _validate_name("end-"))
    assert any("consecutive" in e for e in _validate_name("a--b"))


def test_validate_description_empty():
    assert _validate_description(None) != []
    assert _validate_description("") != []
    assert _validate_description("  ") != []


def test_validate_description_valid():
    assert _validate_description("A valid description") == []


def test_validate_description_too_long():
    assert _validate_description("x" * 1025) != []


def test_load_skills_from_dir_empty():
    with tempfile.TemporaryDirectory() as tmp:
        result = load_skills_from_dir(tmp, "project")
        assert result.skills == []
        assert result.diagnostics == []


def test_load_skills_from_dir_with_skill():
    with tempfile.TemporaryDirectory() as tmp:
        skill_dir = os.path.join(tmp, "my-skill")
        os.makedirs(skill_dir)
        Path(os.path.join(skill_dir, "SKILL.md")).write_text(
            "---\nname: my-skill\ndescription: A test skill\n---\nBody"
        )
        result = load_skills_from_dir(tmp, "project")
        assert len(result.skills) == 1
        assert result.skills[0].name == "my-skill"
        assert result.skills[0].description == "A test skill"
        assert result.skills[0].source == "project"


def test_load_skills_from_dir_infer_name():
    with tempfile.TemporaryDirectory() as tmp:
        skill_dir = os.path.join(tmp, "auto-named")
        os.makedirs(skill_dir)
        Path(os.path.join(skill_dir, "SKILL.md")).write_text(
            "---\ndescription: Inferred name\n---\nBody"
        )
        result = load_skills_from_dir(tmp, "builtin")
        assert result.skills[0].name == "auto-named"


def test_load_skills_from_dir_missing_description():
    with tempfile.TemporaryDirectory() as tmp:
        skill_dir = os.path.join(tmp, "no-desc")
        os.makedirs(skill_dir)
        Path(os.path.join(skill_dir, "SKILL.md")).write_text("---\n---\nBody")
        result = load_skills_from_dir(tmp, "project")
        assert result.skills == []
        assert any("description is required" in d.message for d in result.diagnostics)


def test_load_skills_disable_model_invocation():
    with tempfile.TemporaryDirectory() as tmp:
        skill_dir = os.path.join(tmp, "hidden")
        os.makedirs(skill_dir)
        Path(os.path.join(skill_dir, "SKILL.md")).write_text(
            "---\ndescription: hidden\ndisable-model-invocation: true\n---\nBody"
        )
        result = load_skills_from_dir(tmp, "project")
        assert result.skills[0].disableModelInvocation is True


def test_format_skills_for_prompt_empty():
    assert format_skills_for_prompt([]) == ""


def test_format_skills_for_prompt():
    from _skills_toolchain import Skill
    skills = [Skill(
        name="test-skill", description="A <test> & skill",
        filePath="/path/to/SKILL.md", baseDir="/path/to",
        source="builtin", disableModelInvocation=False,
    )]
    text = format_skills_for_prompt(skills)
    assert "<available_skills>" in text
    assert "test-skill" in text
    assert "&lt;test&gt;" in text
    assert "&amp;" in text


def test_format_skills_excludes_disabled():
    from _skills_toolchain import Skill
    skills = [Skill(
        name="hidden", description="Hidden skill",
        filePath="/p", baseDir="/p", source="builtin", disableModelInvocation=True,
    )]
    assert format_skills_for_prompt(skills) == ""


def test_append_skills_to_prompt():
    result = append_skills_to_prompt("base prompt", [])
    assert result == "base prompt"


def test_expand_skill_command_no_match():
    assert expand_skill_command("/other", []) == "/other"
    assert expand_skill_command("plain text", []) == "plain text"


def test_expand_skill_command_match():
    with tempfile.TemporaryDirectory() as tmp:
        skill_dir = os.path.join(tmp, "my-skill")
        os.makedirs(skill_dir)
        Path(os.path.join(skill_dir, "SKILL.md")).write_text(
            "---\nname: my-skill\ndescription: test\n---\nSkill body here"
        )
        result = load_skills_from_dir(tmp, "project")
        expanded = expand_skill_command("/skill:my-skill extra arg", result.skills)
        assert "Skill body here" in expanded
        assert "extra arg" in expanded


def test_load_skill_by_dir():
    # Uses the jackal repo itself
    repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
    skill_dir = os.path.join(repo_root, "pi", "skills")
    if os.path.isdir(skill_dir):
        body = load_skill_by_dir("fix-skill", repo_root)
        # Just check it's non-empty (exact content varies)
        assert isinstance(body, str)


def test_skill_read_allowlist():
    from _skills_toolchain import Skill
    skills = [Skill(
        name="s", description="d", filePath="/a/b/SKILL.md",
        baseDir="/a/b", source="project", disableModelInvocation=False,
    )]
    result = skill_read_allowlist(skills)
    assert "/a/b/SKILL.md" in result["files"]
    assert "/a/b/" in result["roots"]


def test_load_jackal_skills_explicit_path():
    with tempfile.TemporaryDirectory() as tmp:
        skill_dir = os.path.join(tmp, "my-skill")
        os.makedirs(skill_dir)
        Path(os.path.join(skill_dir, "SKILL.md")).write_text(
            "---\nname: my-explicit\ndescription: explicit path\n---\nBody"
        )
        result = load_jackal_skills(
            cwd=tmp, include_defaults=False, skill_paths=[skill_dir],
        )
        assert len(result.skills) == 1
        assert result.skills[0].name == "my-explicit"


def test_load_jackal_skills_collision():
    with tempfile.TemporaryDirectory() as tmp:
        for i, src in enumerate(["a", "b"]):
            d = os.path.join(tmp, f"dir{i}")
            os.makedirs(d)
            Path(os.path.join(d, "SKILL.md")).write_text(
                f"---\nname: same-name\ndescription: desc {i}\n---\nBody"
            )
        result = load_jackal_skills(
            cwd=tmp, include_defaults=False,
            skill_paths=[os.path.join(tmp, "dir0"), os.path.join(tmp, "dir1")],
        )
        # One skill wins, collision diagnostic
        assert len(result.skills) == 1
        assert any(d.type == "collision" for d in result.diagnostics)


# =============================================================================
# Project init tests
# =============================================================================

def test_parse_jac_toml():
    with tempfile.TemporaryDirectory() as tmp:
        Path(os.path.join(tmp, "jac.toml")).write_text(
            'name = "my-project"\ndescription = "A test"\nentry-point = "main.jac"\n'
        )
        result = _parse_jac_toml(tmp)
        assert result["name"] == "my-project"
        assert result["description"] == "A test"
        assert result["entryPoint"] == "main.jac"


def test_parse_jac_toml_missing():
    with tempfile.TemporaryDirectory() as tmp:
        result = _parse_jac_toml(tmp)
        assert result["name"] == ""
        assert result["entryPoint"] is None


def test_classify_project():
    assert _classify_project(["app.sv.jac", "app.cl.jac"], True, None) == "fullstack"
    assert _classify_project(["app.sv.jac"], True, None) == "api"
    assert _classify_project(["app.cl.jac"], True, None) == "client-only"
    assert _classify_project(["main.jac"], True, "main.jac") == "library"
    assert _classify_project(["module.jac"], True, None) == "mixed"
    assert _classify_project([], False, None) == "non-jac"


def test_analyze_project():
    with tempfile.TemporaryDirectory() as tmp:
        Path(os.path.join(tmp, "jac.toml")).write_text(
            'name = "test-proj"\ndescription = "Test"\n'
        )
        Path(os.path.join(tmp, "main.jac")).write_text("")
        info = analyze_project(tmp)
        assert info["projectName"] == "test-proj"
        assert info["description"] == "Test"
        assert info["hasJacToml"] is True
        assert len(info["jacFiles"]) == 1
        assert info["projectType"] == "mixed"


def test_generate_agents_md():
    info = {
        "projectName": "test-proj",
        "description": "A test project",
        "projectType": "fullstack",
        "jacVersion": "0.7.0",
        "pythonVersion": "Python 3.12",
        "hasJacToml": True,
        "hasVenv": False,
        "npmDeps": ["ink", "react"],
        "jacTomlEntry": "main.jac",
        "jacFiles": ["main.jac", "app.sv.jac", "app.cl.jac"],
        "pythonFiles": [],
        "hasTests": True,
        "hasGit": True,
        "hasReadme": True,
        "hasAgentsMd": False,
        "hasJackalConfig": False,
    }
    md = generate_agents_md(info)
    assert "# test-proj" in md
    assert "fullstack" in md
    assert "main.jac" in md
    assert "ink, react" in md
    assert "jac check" in md
    assert "jac test" in md
    assert ".jackal" in md


def test_run_project_init():
    with tempfile.TemporaryDirectory() as tmp:
        Path(os.path.join(tmp, "jac.toml")).write_text('name = "init-test"\n')
        result = run_project_init(tmp)
        assert result["written"] is True
        assert os.path.isfile(result["path"])
        content = Path(result["path"]).read_text()
        assert "<!-- jackal-init -->" in content
        assert "init-test" in content


def test_run_project_init_no_overwrite():
    with tempfile.TemporaryDirectory() as tmp:
        Path(os.path.join(tmp, "AGENTS.md")).write_text("existing")
        result = run_project_init(tmp)
        assert result["written"] is False
        assert "already exists" in result["content"]


def test_run_project_init_force():
    with tempfile.TemporaryDirectory() as tmp:
        Path(os.path.join(tmp, "AGENTS.md")).write_text("existing")
        Path(os.path.join(tmp, "jac.toml")).write_text('name = "forced"\n')
        result = run_project_init(tmp, force=True)
        assert result["written"] is True
        assert "forced" in result["content"]


# =============================================================================
# MCP schema tests
# =============================================================================

def test_mcp_input_schema_none():
    result = mcp_input_schema_to_parameters(None)
    assert result["type"] == "object"


def test_mcp_input_schema_passthrough():
    schema = {"type": "object", "properties": {"q": {"type": "string"}}}
    assert mcp_input_schema_to_parameters(schema) == schema


def test_coerce_string():
    assert coerce_by_schema("hello", {"type": "string"}) == "hello"
    assert coerce_by_schema(42, {"type": "string"}) == "42"


def test_coerce_number():
    assert coerce_by_schema(3.14, {"type": "number"}) == 3.14
    assert coerce_by_schema("3.14", {"type": "number"}) == 3.14


def test_coerce_integer():
    assert coerce_by_schema(42, {"type": "integer"}) == 42
    assert coerce_by_schema("42", {"type": "integer"}) == 42


def test_coerce_boolean():
    assert coerce_by_schema(True, {"type": "boolean"}) is True
    assert coerce_by_schema("true", {"type": "boolean"}) is True
    assert coerce_by_schema("false", {"type": "boolean"}) is False


def test_coerce_array():
    assert coerce_by_schema([1, 2], {"type": "array"}) == [1, 2]
    assert coerce_by_schema("[1,2]", {"type": "array"}) == [1, 2]


def test_coerce_object():
    assert coerce_by_schema({"a": 1}, {"type": "object"}) == {"a": 1}
    assert coerce_by_schema('{"a":1}', {"type": "object"}) == {"a": 1}


def test_coerce_passthrough():
    assert coerce_by_schema("anything", {"type": "unknown"}) == "anything"


def test_validate_and_coerce():
    schema = {
        "type": "object",
        "properties": {"count": {"type": "integer"}},
        "required": ["count"],
    }
    result = validate_and_coerce_args(schema, {"count": "42"})
    assert result["count"] == 42


def test_validate_and_coerce_missing_required():
    import pytest
    schema = {"type": "object", "properties": {}, "required": ["name"]}
    with pytest.raises(ValueError, match="Missing required"):
        validate_and_coerce_args(schema, {})


def test_validate_and_coerce_no_schema():
    assert validate_and_coerce_args(None, {"a": 1}) == {"a": 1}


# =============================================================================
# Task tools tests
# =============================================================================

def test_validate_create_tasks_empty():
    import pytest
    with pytest.raises(ValueError, match="At least one"):
        validate_create_tasks({"tasks": []})


def test_validate_create_tasks_empty_title():
    import pytest
    with pytest.raises(ValueError, match="cannot be empty"):
        validate_create_tasks({"tasks": [{"title": ""}]})


def test_validate_create_tasks_long_title():
    import pytest
    with pytest.raises(ValueError, match="too long"):
        validate_create_tasks({"tasks": [{"title": "x" * 201}]})


def test_validate_create_tasks_valid():
    result = validate_create_tasks({"tasks": [{"title": "My task", "description": "desc"}]})
    assert len(result) == 1
    assert result[0]["title"] == "My task"


def test_validate_update_tasks_empty():
    import pytest
    with pytest.raises(ValueError, match="At least one"):
        validate_update_tasks({"updates": []})


def test_validate_update_tasks_no_id():
    import pytest
    with pytest.raises(ValueError, match="Task ID is required"):
        validate_update_tasks({"updates": [{"status": "completed"}]})


def test_validate_update_tasks_no_fields():
    import pytest
    with pytest.raises(ValueError, match="At least one field"):
        validate_update_tasks({"updates": [{"id": "abc"}]})


def test_validate_delete_tasks_neither():
    import pytest
    with pytest.raises(ValueError, match="Either ids or clear_all"):
        validate_delete_tasks({})


def test_validate_delete_tasks_both():
    import pytest
    with pytest.raises(ValueError, match="Cannot specify both"):
        validate_delete_tasks({"ids": ["a"], "clear_all": True})


def test_build_create_result():
    with tempfile.TemporaryDirectory() as tmp:
        result = build_create_result(tmp, [
            {"title": "Task 1"},
            {"title": "Task 2", "description": "desc"},
        ])
        assert "Created 2 task(s)" in result["text"]
        assert len(result["created"]) == 2
        assert result["created"][0]["title"] == "Task 1"


def test_build_list_result_empty():
    with tempfile.TemporaryDirectory() as tmp:
        result = build_list_result(tmp)
        assert "No tasks found" in result["text"]


def test_build_list_result_with_tasks():
    with tempfile.TemporaryDirectory() as tmp:
        build_create_result(tmp, [{"title": "T1"}])
        result = build_list_result(tmp)
        assert "T1" in result["text"]
        assert len(result["tasks"]) == 1


def test_build_delete_result_by_ids():
    with tempfile.TemporaryDirectory() as tmp:
        created = build_create_result(tmp, [{"title": "A"}, {"title": "B"}])
        ids = [t["id"] for t in created["created"]]
        result = build_delete_result(tmp, {"ids": [ids[0]]})
        assert "Deleted 1 task(s)" in result["text"]


def test_build_delete_result_clear_all():
    with tempfile.TemporaryDirectory() as tmp:
        build_create_result(tmp, [{"title": "A"}, {"title": "B"}])
        result = build_delete_result(tmp, {"clear_all": True})
        assert "Cleared all 2 task(s)" in result["text"]


# =============================================================================
# Web tools tests
# =============================================================================

def test_assert_safe_url_valid():
    assert assert_safe_fetch_url("https://example.com") == "https://example.com"


def test_assert_safe_url_ftp():
    import pytest
    with pytest.raises(ValueError, match="http"):
        assert_safe_fetch_url("ftp://example.com")


def test_assert_safe_url_localhost():
    import pytest
    with pytest.raises(ValueError, match="Loopback"):
        assert_safe_fetch_url("http://localhost:3000")


def test_assert_safe_url_private_ip():
    import pytest
    with pytest.raises(ValueError, match="Private"):
        assert_safe_fetch_url("http://192.168.1.1")


def test_assert_safe_url_internal():
    import pytest
    with pytest.raises(ValueError, match="Internal"):
        assert_safe_fetch_url("http://metadata.google.internal")


def test_html_to_readable_text():
    html = "<html><head><title>Test</title></head><body><h1>Hello</h1><p>World</p></body></html>"
    text = html_to_readable_text(html)
    assert "Hello" in text
    assert "World" in text


def test_html_to_readable_text_strip_scripts():
    html = "<script>alert('x')</script><p>Safe</p>"
    text = html_to_readable_text(html)
    assert "alert" not in text
    assert "Safe" in text


def test_html_to_readable_text_entities():
    html = "<p>a &amp; b &lt; c &gt; d</p>"
    text = html_to_readable_text(html)
    assert "a & b" in text
    assert "< c" in text


def test_format_web_search_results_empty():
    assert format_web_search_results([]) == "No results found."


def test_format_web_search_results():
    results = [
        {"title": "Test", "url": "https://example.com", "description": "A result"},
    ]
    text = format_web_search_results(results)
    assert "1. Test" in text
    assert "https://example.com" in text
    assert "A result" in text


def test_parse_brave_search_response():
    data = {
        "web": {
            "results": [
                {"title": "A", "url": "https://a.com", "description": "desc a"},
                {"title": "B", "url": "https://b.com"},
            ]
        }
    }
    results = parse_brave_search_response(data)
    assert len(results) == 2
    assert results[0]["title"] == "A"
    assert results[1]["description"] == ""  # missing → empty string


def test_parse_brave_search_response_empty():
    assert parse_brave_search_response(None) == []
    assert parse_brave_search_response({}) == []
    assert parse_brave_search_response({"web": {}}) == []
