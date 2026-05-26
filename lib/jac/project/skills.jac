"""Skills discovery, loading, formatting — builtin/user/project skill resolution."""

::py::
import os
import sys as _sys

_pkg = os.path.join(os.getcwd(), "lib", "jac", "project")
if _pkg not in _sys.path:
    _sys.path.insert(0, _pkg)

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
::py::

# ---------- tests ----------

test "validate name valid" {
    assert _validate_name("my-skill") == [];
    assert _validate_name("abc123") == [];
}

test "validate name too long" {
    errors = _validate_name("a" * 65);
    assert any("exceeds" in e for e in errors);
}

test "validate name invalid chars" {
    errors = _validate_name("My_Skill");
    assert any("invalid characters" in e for e in errors);
}

test "validate description empty" {
    assert _validate_description(None) != [];
    assert _validate_description("") != [];
    assert _validate_description("  ") != [];
}

test "validate description valid" {
    assert _validate_description("A valid description") == [];
}

test "format skills for prompt empty" {
    assert format_skills_for_prompt([]) == "";
}

test "format skills for prompt" {
    skills = [{
        "name": "test-skill", "description": "A <test> & skill",
        "filePath": "/path/to/SKILL.md", "baseDir": "/path/to",
        "source": "builtin", "disableModelInvocation": False,
    }];
    text = format_skills_for_prompt(skills);
    assert "<available_skills>" in text;
    assert "test-skill" in text;
    assert "&lt;test&gt;" in text;
}

test "format skills excludes disabled" {
    skills = [{
        "name": "hidden", "description": "Hidden",
        "filePath": "/p", "baseDir": "/p", "source": "builtin", "disableModelInvocation": True,
    }];
    assert format_skills_for_prompt(skills) == "";
}

test "append skills to prompt no skills" {
    assert append_skills_to_prompt("base", []) == "base";
}

test "expand skill command no match" {
    assert expand_skill_command("/other", []) == "/other";
    assert expand_skill_command("plain text", []) == "plain text";
}

test "skill read allowlist" {
    skills = [{
        "name": "s", "description": "d", "filePath": "/a/b/SKILL.md",
        "baseDir": "/a/b", "source": "project", "disableModelInvocation": False,
    }];
    result = skill_read_allowlist(skills);
    assert "/a/b/SKILL.md" in result["files"];
    assert "/a/b/" in result["roots"];
}
