"""Chain catalog tests for agent/chains.jac (same-stem annex).

Covers: recursive .chain.md discovery, step config parsing (output,
comma reads list, model, task text after the first blank line, no-blank
degenerate bodies), full chain markdown parsing (multi-step sections),
ValueError on missing name/description and zero steps, directory loads
skipping invalid files, package+project merge with project-wins
precedence plus sorted listing and lookup, chain_dirs_exist probing,
catalog formatting with the arrow step summary, and one smoke test over
the REAL repo chains under pi/chains (read-only). Every fixture lives in
a Python tempfile tree removed per test -- the real pi/chains data is
never modified.

Typing note: values pulled out of untyped dicts/lists arrive as
<Unknown> to the Jac checker, so this file funnels them through explicit
locals or str()/dict() casts before use.
"""

import os;
import tempfile;
import shutil;


def _make_tmp() -> str {
    return tempfile.mkdtemp(prefix="jackal-chains-test-");
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


def _chain_names(chains: list) -> list[str] {
    out: list[str] = [];
    for c in chains {
        rec: dict = c;
        out.append(str(rec["name"]));
    }
    return out;
}


test "list_chain_files finds nested chain files only" {
    tmp = _make_tmp();
    try {
        nested = os.path.join(tmp, "sub");
        a = os.path.join(tmp, "pipeline.chain.md");
        b = os.path.join(nested, "extra.chain.md");
        _write_text(a, "---\nname: a\ndescription: A\n---\n\n## scout\nGo.");
        _write_text(b, "---\nname: b\ndescription: B\n---\n\n## worker\nDo.");
        # Non-chain files ignored.
        _write_text(os.path.join(tmp, "agent.md"), "not a chain");
        _write_text(os.path.join(tmp, "notes.txt"), "nope");

        found = list_chain_files(tmp);
        assert found == [a, b];
        assert list_chain_files(os.path.join(tmp, "missing")) == [];
    } finally {
        _cleanup(tmp);
    }
}


test "parse_step_body splits config block from task text" {
    body = "output: context.md\nreads: a.md, b.md ,  \nmodel: claude-sonnet-4-5\n\nInvestigate {task}\nline two.";
    step = parse_step_body("scout", body);
    assert str(step["agent"]) == "scout";
    assert str(step["task"]) == "Investigate {task}\nline two.";
    assert str(step["output"]) == "context.md";
    reads: any = step["reads"];
    assert isinstance(reads, list);
    assert [str(r) for r in reads] == ["a.md", "b.md"];
    assert str(step["model"]) == "claude-sonnet-4-5";

    # Unknown keys and valueless keys are dropped; blank line separates
    # the config block from the task text.
    bare = parse_step_body("worker", "priority: high\noutput:\n\nJust do it.");
    assert "output" not in bare;
    assert "priority" not in bare;
    assert str(bare["task"]) == "Just do it.";

    # No blank line at all -> empty task, config lines still scanned.
    tight = parse_step_body("planner", "model: m1");
    assert str(tight["task"]) == "";
    assert str(tight["model"]) == "m1";
}


def _sample_chain() -> str {
    return (
        "---\nname: pipeline\ndescription: Full flow\n---\n"
        "\n"
        "## scout\n"
        "output: context.md\n"
        "\n"
        "Investigate the project for {task}.\n"
        "\n"
        "Return findings.\n"
        "\n"
        "## Planner \n"
        "reads: context.md\n"
        "MODEL: reasoner-model\n"
        "\n"
        "Design the graph for {task}.\n"
        "\n"
        "## worker\n"
        "\n"
        "Execute:\n\n{previous}\n"
    );
}


test "parse_chain_markdown extracts frontmatter and ordered steps" {
    tmp = _make_tmp();
    try {
        path = os.path.join(tmp, "pipeline.chain.md");
        _write_text(path, _sample_chain());
        chain = parse_chain_markdown(_sample_chain(), "package", path);
        assert str(chain["name"]) == "pipeline";
        assert str(chain["description"]) == "Full flow";
        assert str(chain["source"]) == "package";
        assert str(chain["filePath"]) == path;

        steps: list = chain["steps"];
        assert len(steps) == 3;
        s0: dict = steps[0];
        assert str(s0["agent"]) == "scout";
        assert str(s0["output"]) == "context.md";
        assert str(s0["task"]).startswith("Investigate the project");
        s1: dict = steps[1];
        # Agent names are trimmed; keys are case-insensitive (MODEL works).
        assert str(s1["agent"]) == "Planner";
        assert str(s1["model"]) == "reasoner-model";
        reads1: any = s1["reads"];
        assert isinstance(reads1, list);
        assert [str(r) for r in reads1] == ["context.md"];
        s2: dict = steps[2];
        assert str(s2["agent"]) == "worker";
        assert "{previous}" in str(s2["task"]);
        # Steps without config lines carry no optional keys.
        assert "model" not in s2;
    } finally {
        _cleanup(tmp);
    }
}


test "parse_chain_markdown rejects bad frontmatter and stepless chains" {
    tmp = _make_tmp();
    try {
        raised = False;
        try {
            parse_chain_markdown("---\nname: only-name\n---\n\n## scout\nGo.", "package", "x.md");
        } except ValueError {
            raised = True;
        }
        assert raised;

        raised2 = False;
        try {
            parse_chain_markdown("---\ndescription: only-desc\n---\n\n## scout\nGo.", "package", "x.md");
        } except ValueError {
            raised2 = True;
        }
        assert raised2;

        raised3 = False;
        try {
            parse_chain_markdown("---\nname: c\ndescription: d\n---\n\nNo headings here.", "package", "x.md");
        } except ValueError {
            raised3 = True;
        }
        assert raised3;

        # Only ### headings do not count as steps.
        raised4 = False;
        try {
            parse_chain_markdown("---\nname: c\ndescription: d\n---\n\n### scout\nGo.", "package", "x.md");
        } except ValueError {
            raised4 = True;
        }
        assert raised4;
    } finally {
        _cleanup(tmp);
    }
}


test "load_chains_from_dir skips invalid chain files silently" {
    tmp = _make_tmp();
    try {
        good_path = os.path.join(tmp, "good.chain.md");
        _write_text(good_path, "---\nname: good\ndescription: fine\n---\n\n## scout\nGo.");
        _write_text(os.path.join(tmp, "bad.chain.md"),
                    "---\nname: no-steps-here\ndescription: x\n---\n\nnothing useful");
        _write_text(os.path.join(tmp, "broken.chain.md"),
                    "---\ndescription: missing name\n---\n\n## scout\nGo.");

        loaded = load_chains_from_dir(tmp, "project");
        assert _chain_names(loaded) == ["good"];
        first: dict = loaded[0];
        assert str(first["filePath"]) == good_path;
        assert str(first["source"]) == "project";
    } finally {
        _cleanup(tmp);
    }
}


test "load_chains merges package and project with project winning" {
    tmp = _make_tmp();
    try {
        pkg = os.path.join(tmp, "pkg");
        cwd = os.path.join(tmp, "proj");
        _write_text(os.path.join(pkg, "chains", "alpha.chain.md"),
                    "---\nname: alpha\ndescription: pkg alpha\n---\n\n## scout\nGo.");
        _write_text(os.path.join(pkg, "chains", "nested", "beta.chain.md"),
                    "---\nname: beta\ndescription: pkg beta\n---\n\n## worker\nDo.");
        _write_text(os.path.join(cwd, "chains", "alpha.chain.md"),
                    "---\nname: alpha\ndescription: project alpha\n---\n\n## planner\nPlan.");

        merged = load_chains(cwd, pkg);
        assert sorted([str(k) for k in merged.keys()]) == ["alpha", "beta"];
        alpha: dict = merged["alpha"];
        assert str(alpha["description"]) == "project alpha";
        assert str(alpha["source"]) == "project";
        beta: dict = merged["beta"];
        assert str(beta["source"]) == "package";

        listed = list_chains(cwd, pkg);
        assert _chain_names(listed) == ["alpha", "beta"];  # sorted

        picked: dict | None = get_chain(cwd, " beta ", pkg);
        assert picked is not None;
        assert str(picked["description"]) == "pkg beta";
        assert get_chain(cwd, "ghost", pkg) is None;
    } finally {
        _cleanup(tmp);
    }
}


test "discover_chain_dirs and chain_dirs_exist probe both roots" {
    tmp = _make_tmp();
    try {
        pkg = os.path.join(tmp, "pkg");
        cwd = os.path.join(tmp, "proj");
        dirs = discover_chain_dirs(cwd, pkg);
        assert str(dirs["packageDir"]) == os.path.join(pkg, "chains");
        assert str(dirs["projectDir"]) == os.path.join(cwd, "chains");

        assert not chain_dirs_exist(cwd, pkg);
        os.makedirs(os.path.join(cwd, "chains"), exist_ok=True);
        assert chain_dirs_exist(cwd, pkg);
        os.makedirs(os.path.join(pkg, "chains"), exist_ok=True);
        assert chain_dirs_exist(cwd, pkg);

        # Empty-but-existing dirs load as no chains at all.
        assert load_chains(cwd, pkg) == {};
        assert format_chain_catalog(cwd, pkg) == "No chains found.";
    } finally {
        _cleanup(tmp);
    }
}


test "format_chain_catalog renders arrow step summaries" {
    tmp = _make_tmp();
    try {
        pkg = os.path.join(tmp, "pkg");
        cwd = os.path.join(tmp, "proj");
        _write_text(os.path.join(pkg, "chains", "flow.chain.md"), _sample_chain());

        text = format_chain_catalog(cwd, pkg);
        assert text.startswith("Available chains:");
        # Catalog shows the frontmatter name, not the file name.
        assert "- pipeline (package) — Full flow" in text;
        assert "steps: scout → Planner → worker" in text;
    } finally {
        _cleanup(tmp);
    }
}


test "real repo chains smoke-parse read-only" {
    repo_pi = "/home/jac/repos/jackal/pi";
    scratch = _make_tmp();
    try {
        merged = load_chains(scratch, repo_pi);
        assert sorted([str(k) for k in merged.keys()]) == ["pipeline", "scout-and-design"];

        pipe: dict | None = get_chain(scratch, "pipeline", repo_pi);
        assert pipe is not None;
        assert str(pipe["source"]) == "package";
        steps: list = pipe["steps"];
        agents_seq: list[str] = [];
        for s in steps {
            rec: dict = s;
            agents_seq.append(str(rec["agent"]));
        }
        assert agents_seq == ["scout", "planner", "worker"];
        first: dict = steps[0];
        assert str(first.get("output", "")) == "context.md";
        second: dict = steps[1];
        assert str(second.get("model", "")) != "";

        text = format_chain_catalog(scratch, repo_pi);
        assert "scout → planner → worker" in text;
    } finally {
        _cleanup(scratch);
    }
}
