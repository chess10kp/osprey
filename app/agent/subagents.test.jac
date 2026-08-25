"""Subagent catalog tests for agent/subagents.jac (same-stem annex).

Covers: recursive .md discovery across nested dirs with *.chain.md
exclusion, frontmatter field extraction (name/description/tools inline +
dash lists/model/systemPrompt), invalid or unreadable agent files being
tolerated (None / skipped, never raised), package+project merge with
project-wins precedence, sorted listing and name lookup including
whitespace tolerance and unknown names, tool normalization (aliases,
mcp: passthrough, empty -> None), subagent tool filtering (excluded set,
bash re-pin, empty fallback), settings.json and `.jackal` project model
overrides (including corrupt/absent files), catalog formatting, and one
smoke test over the REAL repo catalog under pi/.pi/agents (read-only).
Every fixture lives in a Python tempfile tree removed per test -- the
real pi/.pi/agents data is never modified.

Typing note: values pulled out of untyped dicts/lists arrive as
<Unknown> to the Jac checker, so this file funnels them through explicit
locals or str()/dict() casts before use.
"""

import os;
import json;
import tempfile;
import shutil;


def _make_tmp() -> str {
    return tempfile.mkdtemp(prefix="jackal-subagents-test-");
}


def _cleanup(tmp: str) {
    shutil.rmtree(tmp, ignore_errors=True);
}


"""str-typed shim over os.path.dirname, which demands PathLike here."""
def _parent_dir(p: any) -> str {
    return str(os.path.dirname(p));
}


def _write_text(path: str, text: str) {
    os.makedirs(_parent_dir(path), exist_ok=True);
    fh = open(path, "w");
    try {
        fh.write(text);
    } finally {
        fh.close();
    }
}


def _write_agent(dir_path: str, fname: str, fm: str, body: str) -> str {
    path = os.path.join(dir_path, fname);
    _write_text(path, "---\n" + fm + "\n---\n\n" + body + "\n");
    return path;
}


def _agent_names(agents: list) -> list[str] {
    out: list[str] = [];
    for a in agents {
        rec: dict = a;
        out.append(str(rec["name"]));
    }
    return out;
}


test "discovery finds agents in nested dirs but skips chain files and non-md" {
    tmp = _make_tmp();
    try {
        pkg = os.path.join(tmp, "pkg");
        flat = os.path.join(pkg, ".pi", "agents");
        deeper = os.path.join(flat, "specialists", "deep");
        scout = _write_agent(flat, "scout.md", "name: scout\ndescription: Recon", "Scout body.");
        worker = _write_agent(deeper, "worker.md", "name: worker\ndescription: Does work", "Work body.");
        _write_agent(flat, "pipeline.chain.md", "name: pipeline\ndescription: chain", "## scout");
        _write_text(os.path.join(flat, "notes.txt"), "not markdown");

        found = load_agents_from_dir(os.path.join(pkg, ".pi", "agents"), "package");
        assert sorted(_agent_names(found)) == ["scout", "worker"];
        paths: list[str] = [];
        for a in found {
            rec: dict = a;
            paths.append(str(rec["filePath"]));
        }
        assert sorted(paths) == sorted([scout, worker]);
        for a in found {
            rec2: dict = a;
            assert str(rec2["source"]) == "package";
        }

        # Missing directory yields nothing, not an error.
        assert load_agents_from_dir(os.path.join(tmp, "nope"), "package") == [];
    } finally {
        _cleanup(tmp);
    }
}


test "load_agent_file extracts name description tools model systemPrompt" {
    tmp = _make_tmp();
    try {
        # Inline tools list.
        p1 = _write_agent(
            tmp, "inline.md",
            'name:  Scout\ndescription:   Fast recon agent  \ntools: read, grep, find\nmodel: claude-haiku-4-5',
            "You are a scout.\nBe quick.",
        );
        agent1 = load_agent_file(p1, "package");
        assert agent1 is not None;
        assert str(agent1["name"]) == "Scout";
        assert str(agent1["description"]) == "Fast recon agent";
        tools1: any = agent1["tools"];
        assert isinstance(tools1, list);
        assert [str(t) for t in tools1] == ["read", "grep", "find"];
        assert str(agent1["model"]) == "claude-haiku-4-5";
        assert str(agent1["systemPrompt"]) == "You are a scout.\nBe quick.";
        assert str(agent1["source"]) == "package";
        assert str(agent1["filePath"]) == p1;

        # Dash-block tools list, no model -> None.
        p2 = _write_agent(
            tmp, "dash.md",
            "name: architect\ndescription: Designer\ntools:\n  - read\n  - write",
            "Design it.",
        );
        agent2 = load_agent_file(p2, "project");
        assert agent2 is not None;
        tools2: any = agent2["tools"];
        assert isinstance(tools2, list);
        assert [str(t) for t in tools2] == ["read", "write"];
        assert agent2["model"] is None;

        # No tools key at all -> None (meaning all allowed).
        p3 = _write_agent(tmp, "bare.md", "name: bare\ndescription: Bare agent", "Body.");
        agent3 = load_agent_file(p3, "project");
        assert agent3 is not None;
        assert agent3["tools"] is None;
        assert agent3["model"] is None;
    } finally {
        _cleanup(tmp);
    }
}


test "invalid or unreadable agent files are tolerated without raising" {
    tmp = _make_tmp();
    try {
        # Missing name / missing description / no frontmatter at all.
        assert load_agent_file(_write_agent(tmp, "a.md", "description: only desc", "x"), "p") is None;
        assert load_agent_file(_write_agent(tmp, "b.md", "name: only-name", "x"), "p") is None;
        plain = os.path.join(tmp, "c.md");
        _write_text(plain, "just body text, no frontmatter");
        assert load_agent_file(plain, "p") is None;
        # Unterminated frontmatter keeps everything as body -> no name.
        unterminated = os.path.join(tmp, "d.md");
        _write_text(unterminated, "---\nname: ghost\ndescription: never closed");
        assert load_agent_file(unterminated, "p") is None;
        # Unreadable path.
        assert load_agent_file(os.path.join(tmp, "missing.md"), "p") is None;

        # Directory loader silently skips the bad ones.
        good = _write_agent(tmp, "good.md", "name: good\ndescription: fine", "ok");
        loaded = load_agents_from_dir(tmp, "project");
        assert _agent_names(loaded) == ["good"];
        first: dict = loaded[0];
        assert str(first["filePath"]) == good;
    } finally {
        _cleanup(tmp);
    }
}


test "merge puts project overrides above package by name" {
    tmp = _make_tmp();
    try {
        pkg_agents = os.path.join(tmp, "pkg", ".pi", "agents");
        proj_agents = os.path.join(tmp, "proj", "subagents");
        _write_agent(pkg_agents, "scout.md", "name: scout\ndescription: pkg scout", "pkg body");
        _write_agent(pkg_agents, "planner.md", "name: planner\ndescription: pkg planner", "pkg body");
        _write_agent(proj_agents, "scout.md", "name: scout\ndescription: project scout", "proj body");

        merged = load_subagents(os.path.join(tmp, "proj"), os.path.join(tmp, "pkg"));
        assert sorted([str(k) for k in merged.keys()]) == ["planner", "scout"];
        winner: dict = merged["scout"];
        assert str(winner["description"]) == "project scout";
        assert str(winner["source"]) == "project";
        loser: dict = merged["planner"];
        assert str(loser["source"]) == "package";

        listed = list_subagents(os.path.join(tmp, "proj"), os.path.join(tmp, "pkg"));
        assert _agent_names(listed) == ["planner", "scout"];  # sorted by name

        picked: dict | None = get_subagent(os.path.join(tmp, "proj"), " scout ", os.path.join(tmp, "pkg"));
        assert picked is not None;
        assert str(picked["description"]) == "project scout";
        assert get_subagent(os.path.join(tmp, "proj"), "ghost", os.path.join(tmp, "pkg")) is None;
    } finally {
        _cleanup(tmp);
    }
}


test "normalize_allowed_tool_names applies aliases mcp prefix and empty rule" {
    assert normalize_allowed_tool_names(None) is None;
    assert normalize_allowed_tool_names([]) is None;
    # Blank-only lists normalize to an empty (falsy) set -- callers treat
    # that as "all allowed", matching the toolchain's behavior.
    assert normalize_allowed_tool_names(["   ", ""]) == set();

    got = normalize_allowed_tool_names(["read_file", "grep", "mcp:jac_docs", "custom_tool"]);
    assert got is not None;
    assert got == {"read", "bash", "jac_docs", "custom_tool"};
}


test "filter_tools_for_subagent excludes pins bash and falls back safely" {
    all_tools = ["read", "write", "bash", "agent", "subagent", "compact_context", "mermaid"];

    # No allowlist -> everything except excluded.
    assert filter_tools_for_subagent(all_tools, None) == [
        "read", "write", "bash", "mermaid"
    ];

    # Allowlist intersection.
    got = filter_tools_for_subagent(all_tools, {"read", "bash"});
    assert got == ["read", "bash"];

    # bash allowed but filtered away gets re-pinned when present upstream.
    repinned = filter_tools_for_subagent(all_tools, {"bash", "nonexistent"});
    assert "bash" in repinned;
    assert "nonexistent" not in repinned;

    # Nothing survives -> fallback to all non-excluded.
    assert filter_tools_for_subagent(all_tools, {"only_ghost"}) == [
        "read", "write", "bash", "mermaid"
    ];

    # Excluded names never pass even when explicitly allowed.
    assert filter_tools_for_subagent(all_tools, {"agent", "read"}) == ["read"];

    assert filter_tools_for_subagent([], None) == [];
}


test "settings.json model overrides parse or degrade to empty" {
    tmp = _make_tmp();
    try {
        base = os.path.join(tmp, "root");
        os.makedirs(base, exist_ok=True);
        # No settings.json yet.
        assert load_settings_model_overrides(base) == {};

        _write_text(os.path.join(base, "settings.json"), json.dumps({
            "other": 1,
            "subagents": {
                "agentOverrides": {
                    "scout": {"model": "haiku-latest"},
                    "bad": {"model": 42},
                    "worse": "just-a-string",
                },
            },
        }));
        got = load_settings_model_overrides(base);
        assert got == {"scout": "haiku-latest"};

        _write_text(os.path.join(base, "settings.json"), "{corrupt json");
        assert load_settings_model_overrides(base) == {};
        _write_text(os.path.join(base, "settings.json"), "[1, 2]");
        assert load_settings_model_overrides(base) == {};
    } finally {
        _cleanup(tmp);
    }
}


test "project model overrides come from walked-up .jackal config" {
    tmp = _make_tmp();
    try {
        deep = os.path.join(tmp, "a", "b", "proj");
        cfg = {
            "subagents": {
                "model": "default-model",
                "enabled": True,
                "scout": "fast-model",
                "architect": {"model": "reasoner-model"},
                "broken": 7,
            },
        };
        # Config lives two levels ABOVE the cwd -- walk-up must find it.
        _write_text(os.path.join(tmp, ".jackal"), json.dumps(cfg));

        got = load_project_model_overrides(deep);
        assert got == {
            "__default__": "default-model",
            "scout": "fast-model",
            "architect": "reasoner-model",
        };

        # No subagents section anywhere up the tree -> {}.
        empty = _make_tmp();
        try {
            assert load_project_model_overrides(empty) == {};
        } finally {
            _cleanup(empty);
        }
    } finally {
        _cleanup(tmp);
    }
}


test "format_subagent_catalog renders entries and the empty message" {
    tmp = _make_tmp();
    try {
        empty_dir = _make_tmp();
        try {
            assert format_subagent_catalog(empty_dir, empty_dir) == "No subagents found.";
        } finally {
            _cleanup(empty_dir);
        }

        pkg = os.path.join(tmp, "pkg");
        cwd = os.path.join(tmp, "proj");
        agents_dir = os.path.join(pkg, ".pi", "agents");
        _write_agent(agents_dir, "zeta.md",
                     "name: zeta\ndescription: Last one\nmodel: big-model", "b");
        _write_agent(agents_dir, "alpha.md",
                     "name: alpha\ndescription: First one\ntools: read, write", "b");

        text = format_subagent_catalog(cwd, pkg);
        assert text.startswith("Available subagents:");
        assert "- alpha (package) — First one" in text;
        assert "tools: 2  model: inherit" in text;
        assert "- zeta (package) — Last one" in text;
        assert "tools: all  model: big-model" in text;
        # Sorted output: alpha line before zeta line.
        assert text.index("alpha") < text.index("zeta");
    } finally {
        _cleanup(tmp);
    }
}


test "real repo builtin catalog smoke-parses read-only" {
    repo_pi = "/home/jac/repos/jackal/pi";
    scratch = _make_tmp();
    try {
        merged = load_subagents(scratch, repo_pi);
        names = sorted([str(k) for k in merged.keys()]);
        assert names == ["architect", "implementer", "scout"];

        scout_rec: dict = merged["scout"];
        assert str(scout_rec["source"]) == "package";
        assert "recon" in str(scout_rec["description"]).lower();
        scout_tools: any = scout_rec["tools"];
        assert isinstance(scout_tools, list) and scout_tools;
        assert str(scout_rec["systemPrompt"]).startswith("You are a Jac/Jaseci specialist scout.");
        assert str(scout_rec["model"]) != "";

        arch_rec: dict = merged["architect"];
        arch_tools: any = arch_rec["tools"];
        assert isinstance(arch_tools, list);
        normalized = normalize_allowed_tool_names([str(t) for t in arch_tools]);
        assert normalized is not None and "read" in normalized;
    } finally {
        _cleanup(scratch);
    }
}
