"""Project initializer — analyze a Jac project and generate AGENTS.md."""

::py::
import os
import sys as _sys

_pkg = os.path.join(os.getcwd(), "lib", "jac", "project")
if _pkg not in _sys.path:
    _sys.path.insert(0, _pkg)

from _project_init_toolchain import (
    analyze_project,
    generate_agents_md,
    run_project_init,
    _parse_jac_toml,
    _classify_project,
)
::py::

# ---------- tests ----------

test "classify project fullstack" {
    assert _classify_project(["app.sv.jac", "app.cl.jac"], True, None) == "fullstack";
}

test "classify project api" {
    assert _classify_project(["app.sv.jac"], True, None) == "api";
}

test "classify project client only" {
    assert _classify_project(["app.cl.jac"], True, None) == "client-only";
}

test "classify project library" {
    assert _classify_project(["main.jac"], True, "main.jac") == "library";
}

test "classify project mixed" {
    assert _classify_project(["module.jac"], True, None) == "mixed";
}

test "classify project non jac" {
    assert _classify_project([], False, None) == "non-jac";
}

test "generate agents md" {
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
    };
    md = generate_agents_md(info);
    assert "# test-proj" in md;
    assert "fullstack" in md;
    assert "main.jac" in md;
    assert "ink, react" in md;
    assert "jac check" in md;
    assert "jac test" in md;
    assert ".jackal" in md;
}
