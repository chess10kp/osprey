"""Skills discovery/indexing tests for agent/skills.jac (same-stem annex).

Covers: the recursive discovery walk (SKILL.md branch claiming, nested
dirs, dot-dir and node_modules skipping, gitignore rules, root-level *.md
pickup), the hand-rolled frontmatter parser (scalars, quotes, inline +
dash lists, absent/unterminated blocks), malformed-SKILL.md tolerance
(warnings, no crashes, description-less exclusion), root merging in
load_jackal_skills (builtin < user < project precedence, name-sorted
output, collision diagnostics, realpath dedup), explicit skill_paths
resolution and error cases, prompt catalog formatting with XML escaping
and the disable flag, /skill:name expansion, load_skill_by_dir, the read
allowlist, and one smoke test over the REAL repo catalog under pi/skills/
(read-only). Every fixture lives in a Python tempfile tree removed per
test -- the real pi/skills data is never modified.

Typing note: values pulled out of untyped dicts/lists arrive as <Unknown>
to the Jac checker, so this file funnels them through explicit locals or
str()/dict() casts before use.
"""


def _make_tmp() -> str {
    return tempfile.mkdtemp(prefix="jackal-skills-test-");
}


def _cleanup(tmp: str) {
    shutil.rmtree(tmp, ignore_errors=True);
}


def _write_text(path: str, text: str) {
    os.makedirs(_dir_name(path), exist_ok=True);
    fh = open(path, "w");
    try {
        fh.write(text);
    } finally {
        fh.close();
    }
}


def _write_bytes_as_latin1(path: str, text: str) {
    # Produces bytes that are INVALID utf-8 without b"" literals.
    os.makedirs(_dir_name(path), exist_ok=True);
    fh = open(path, "w", encoding="latin-1");
    try {
        fh.write(text);
    } finally {
        fh.close();
    }
}


def _write_skill(dir_path: str, name: str, description: str,
                 extra_fm: str = "", body: str = "Skill body text.") -> str {
    fm = "name: " + name + "\ndescription: " + description;
    if extra_fm {
        fm += "\n" + extra_fm;
    }
    path = os.path.join(dir_path, "SKILL.md");
    _write_text(path, "---\n" + fm + "\n---\n\n" + body + "\n");
    return path;
}


def _names(result: dict) -> list[str] {
    out: list[str] = [];
    items: list = result["skills"];
    for item in items {
        rec: dict = item;
        out.append(str(rec["name"]));
    }
    return out;
}


def _diag_types(result: dict, kind: str) -> list[dict] {
    found: list[dict] = [];
    diags: list = result["diagnostics"];
    for d in diags {
        diag: dict = d;
        if str(diag["type"]) == kind {
            found.append(diag);
        }
    }
    return found;
}


test "discovery walk claims SKILL.md branches and skips hidden vendor dirs" {
    tmp = _make_tmp();
    try {
        skills_root = os.path.join(tmp, "skills");
        _write_skill(os.path.join(skills_root, "alpha"), "alpha", "Alpha skill.");
        # Nested two levels deep: beta/tools/SKILL.md is still discovered.
        _write_skill(os.path.join(skills_root, "beta", "tools"), "beta", "Beta tooling.");
        # Hidden dirs, node_modules, and ignored patterns are skipped.
        _write_skill(os.path.join(skills_root, ".hidden"), "secret", "Should not load.");
        _write_skill(os.path.join(skills_root, "node_modules", "dep"), "dep", "Nope.");
        # A .gitignore inside a subdir excludes its sibling SKILL.md.
        _write_text(os.path.join(skills_root, "gamma", ".gitignore"), "SKILL.md\n");
        _write_skill(os.path.join(skills_root, "gamma"), "gamma", "Ignored by rule.");

        result = load_skills_from_dir(skills_root, "project");
        assert sorted(_names(result)) == ["alpha", "beta"];
        assert len(_diag_types(result, "collision")) == 0;

        items: list = result["skills"];
        for item in items {
            s: dict = item;
            assert _base_name(str(s["filePath"])) == "SKILL.md";
            assert str(s["baseDir"]) == _dir_name(str(s["filePath"]));
            assert str(s["source"]) == "project";
            assert s["disableModelInvocation"] is False;
        }

        # Root-level *.md files are picked up at the top of the walk only.
        plain_root = os.path.join(tmp, "plain");
        os.makedirs(plain_root, exist_ok=True);
        _write_skill(os.path.join(plain_root, "nested"), "nested-skill", "Nested.");
        _write_text(
            os.path.join(plain_root, "loose.md"),
            "---\nname: loose-note\ndescription: A root level note.\n---\n\nNote body.\n",
        );
        loose = load_skills_from_dir(plain_root, "builtin");
        assert sorted(_names(loose)) == ["loose-note", "nested-skill"];
        loose_items: list = loose["skills"];
        first: dict = loose_items[0];
        assert str(first["source"]) == "builtin";

        # Missing directory yields an empty result, not an error.
        absent = load_skills_from_dir(os.path.join(tmp, "nope"), "user");
        assert absent["skills"] == [] and absent["diagnostics"] == [];
    } finally {
        _cleanup(tmp);
    }
}


test "frontmatter parser handles scalars, quoting, lists, and absence" {
    doc = (
        "---\n"
        "name: demo-skill\n"
        'quoted: "hello world"\n'
        "apostrophe: 'single quoted'\n"
        "tags: [alpha, beta, gamma]\n"
        "empty_list: []\n"
        "steps:\n"
        "  - first\n"
        "  - second\n"
        "---\n\n"
        "Body line one.\n\nBody line two.\n"
    );
    parsed = parse_frontmatter(doc);
    fm: dict = parsed[0];
    body: str = parsed[1];
    assert str(fm.get("name")) == "demo-skill";
    assert str(fm.get("quoted")) == "hello world";
    assert str(fm.get("apostrophe")) == "single quoted";
    tags: any = fm.get("tags");
    assert tags == ["alpha", "beta", "gamma"];
    assert fm.get("empty_list") == [];
    steps: any = fm.get("steps");
    assert steps == ["first", "second"];
    assert body == "Body line one.\n\nBody line two.";

    # No frontmatter: everything is body.
    parsed2 = parse_frontmatter("just prose, nothing else");
    assert parsed2[0] == {} and parsed2[1] == "just prose, nothing else";

    # Unterminated block: whole text stays body.
    parsed3 = parse_frontmatter("---\nname: never-closed");
    assert parsed3[0] == {} and "never-closed" in parsed3[1];

    # CRLF normalization.
    parsed4 = parse_frontmatter("---\r\nname: crlf\r\ndescription: d\r\n---\r\n\r\nB\r\n");
    fm4: dict = parsed4[0];
    assert str(fm4.get("name")) == "crlf";
    assert parsed4[1] == "B";

    assert frontmatter_string(None) is None;
    assert frontmatter_string("plain") == "plain";
    assert frontmatter_string(["a", "b"]) == "a, b";
}


test "malformed SKILL.md files produce warnings without crashing" {
    tmp = _make_tmp();
    try {
        tree_base = os.path.join(tmp, "skills");
        os.makedirs(tree_base, exist_ok=True);

        # Missing description -> excluded with a warning diagnostic.
        _write_text(os.path.join(tree_base, "nodesc", "SKILL.md"),
                    "---\nname: nodesc\n---\n\nNo description here.\n");
        # Invalid name characters -> warning but still loaded.
        _write_skill(os.path.join(tree_base, "badname"), "Bad Name!", "Still usable.");
        # Name exceeding the length cap.
        long_name = "a" * 80;
        _write_skill(os.path.join(tree_base, "toolong"), long_name, "Too long name.");
        # Empty file.
        _write_text(os.path.join(tree_base, "emptyf", "SKILL.md"), "");
        # Undecodable bytes (latin-1 written 0xFF/0xFE are invalid UTF-8).
        _write_bytes_as_latin1(os.path.join(tree_base, "binary", "SKILL.md"),
                               "\xff\xfe\x00not utf8");
        # Garbage frontmatter that never terminates.
        _write_text(os.path.join(tree_base, "garbled", "SKILL.md"),
                    "---\nname [broken: ===\nno closing delimiter ever");
        _write_skill(os.path.join(tree_base, "goodone"), "goodone", "Fine.");

        result = load_skills_from_dir(tree_base, "path");
        names = _names(result);
        # nodesc/emptyf/binary/garbled excluded; badname+toolong warn but
        # keep loading under their declared (invalid) names -- the dir-name
        # fallback only applies when the frontmatter name is absent/empty.
        assert "nodesc" not in names;
        assert "emptyf" not in names;
        assert "Bad Name!" in names;
        assert long_name in names;

        warnings = _diag_types(result, "warning");
        messages: list[str] = [];
        for w in warnings {
            wd: dict = w;
            messages.append(str(wd["message"]));
        }
        assert any("description is required" in m for m in messages);
        assert any("invalid characters" in m for m in messages);
        assert any("exceeds 64 characters" in m for m in messages);
        assert "goodone" in names;
        for w in warnings {
            wd2: dict = w;
            wp: any = wd2["path"];
            assert str(wp).endswith(".md");
        }

        # The same tree through load_jackal_skills stays crash-free.
        merged = load_jackal_skills(cwd=tmp, package_root=tmp,
                                    agent_dir=os.path.join(tmp, "home"));
        merged_skills: list = merged["skills"];
        assert isinstance(merged_skills, list);
    } finally {
        _cleanup(tmp);
    }
}


test "load_jackal_skills merges roots with precedence, sorting, collisions" {
    tmp = _make_tmp();
    try {
        pkg = os.path.join(tmp, "pkg");
        _write_skill(os.path.join(pkg, "pi", "skills", "zeta"), "zeta", "Built-in zeta.");
        _write_skill(os.path.join(pkg, "pi", "skills", "alpha"), "alpha", "Built-in alpha.");
        dupe_builtin = _write_skill(
            os.path.join(pkg, "pi", "skills", "dupe"), "dupe", "Builtin dupe."
        );

        home = os.path.join(tmp, "home");
        _write_skill(os.path.join(home, "skills", "beta"), "beta", "User beta.");
        dupe_user = _write_skill(
            os.path.join(home, "skills", "dupe"), "dupe", "User dupe wins.",
            extra_fm="disable-model-invocation: true",
        );

        proj = os.path.join(tmp, "proj");
        _write_skill(os.path.join(proj, ".jackal", "skills", "gamma"),
                     "gamma", "Project gamma.");

        result = load_jackal_skills(cwd=proj, package_root=pkg, agent_dir=home);
        # Sorted by name across all roots.
        assert _names(result) == ["alpha", "beta", "dupe", "gamma", "zeta"];

        by_name: dict = {};
        items: list = result["skills"];
        for item in items {
            s: dict = item;
            by_name[str(s["name"])] = s;
        }
        winner_zeta: dict = by_name["zeta"];
        assert str(winner_zeta["source"]) == "builtin";
        winner_beta: dict = by_name["beta"];
        assert str(winner_beta["source"]) == "user";
        winner_gamma: dict = by_name["gamma"];
        assert str(winner_gamma["source"]) == "project";
        # Later root (user) overrides builtin on name collision...
        winner_dupe: dict = by_name["dupe"];
        assert str(winner_dupe["source"]) == "user";
        assert str(winner_dupe["description"]) == "User dupe wins.";
        assert winner_dupe["disableModelInvocation"] is True;
        # ...and records a collision diagnostic pointing both ways.
        collisions = _diag_types(result, "collision");
        assert len(collisions) == 1;
        col0: dict = collisions[0];
        col: any = col0["collision"];
        assert str(col["name"]) == "dupe";
        assert str(col["winnerPath"]) == dupe_user;
        assert str(col["loserPath"]) == dupe_builtin;

        # include_defaults=False loads only explicit paths.
        only_paths = load_jackal_skills(
            cwd=proj, package_root=pkg, agent_dir=home,
            include_defaults=False,
            skill_paths=[os.path.join(pkg, "pi", "skills", "alpha")],
        );
        assert _names(only_paths) == ["alpha"];

        # Project skills dir discovered via walk-up from a nested cwd.
        nested_cwd = os.path.join(proj, "deep", "deeper");
        os.makedirs(nested_cwd, exist_ok=True);
        walked_up = load_jackal_skills(cwd=nested_cwd, package_root=pkg, agent_dir=home);
        assert "gamma" in _names(walked_up);
    } finally {
        _cleanup(tmp);
    }
}


test "explicit skill_paths resolve relative, home, and error cases" {
    tmp = _make_tmp();
    try {
        proj = os.path.join(tmp, "proj");
        target = _write_skill(os.path.join(proj, "local"), "local-one", "Local dir.");
        single_md = _write_text(
            os.path.join(proj, "standalone.md"),
            "---\nname: standalone\ndescription: One file skill.\n---\n\nBody.\n",
        );
        _write_text(os.path.join(proj, "notmd.txt"), "plain text");

        # Relative directory resolves against cwd.
        rel = load_jackal_skills(cwd=proj, include_defaults=False, skill_paths=["local"]);
        assert _names(rel) == ["local-one"];
        rel_items: list = rel["skills"];
        rel0: dict = rel_items[0];
        assert str(rel0["filePath"]) == target;

        # Single .md file loads directly; duplicate paths dedup by realpath.
        solo = load_jackal_skills(cwd=proj, include_defaults=False,
                                  skill_paths=["standalone.md", single_md]);
        assert _names(solo) == ["standalone"];

        # Errors become diagnostics: missing path and non-markdown file.
        errs = load_jackal_skills(cwd=proj, include_defaults=False,
                                  skill_paths=["missing-dir", "notmd.txt"]);
        assert errs["skills"] == [];
        msgs: list[str] = [];
        err_diags: list = errs["diagnostics"];
        for d in err_diags {
            ed: dict = d;
            msgs.append(str(ed["message"]));
        }
        assert any("does not exist" in m for m in msgs);
        assert any("not a markdown file" in m for m in msgs);

        # Paths under the user roots get tagged accordingly.
        home = os.path.join(tmp, "home");
        _write_skill(os.path.join(home, "skills", "homed"), "homed", "From home.");
        tagged = load_jackal_skills(cwd=proj, package_root=proj, agent_dir=home,
                                    include_defaults=False,
                                    skill_paths=[os.path.join(home, "skills", "homed")]);
        tagged_items: list = tagged["skills"];
        tag0: dict = tagged_items[0];
        assert str(tag0["source"]) == "user";

        # Tilde expansion maps into the fake home via HOME env override.
        old_home = os.environ.get("HOME");
        os.environ["HOME"] = home;
        try {
            tilded = load_jackal_skills(cwd=proj, include_defaults=False,
                                        skill_paths=["~/skills/homed"]);
            assert _names(tilded) == ["homed"];
        } finally {
            if old_home is None {
                os.environ.pop("HOME");
            } else {
                os.environ["HOME"] = old_home;
            }
        }
    } finally {
        _cleanup(tmp);
    }
}


test "format_skills_for_prompt escapes xml and honors the disable flag" {
    tmp = _make_tmp();
    try {
        visible: dict = {
            "name": "escaper",
            "description": "Handles a<b & c>d \"quotes\" and 'apos'.",
            "filePath": os.path.join(tmp, "escaper", "SKILL.md"),
            "baseDir": os.path.join(tmp, "escaper"),
            "source": "builtin",
            "disableModelInvocation": False,
        };
        hidden: dict = {
            "name": "hidden-one",
            "description": "Never shown.",
            "filePath": os.path.join(tmp, "hidden-one", "SKILL.md"),
            "baseDir": os.path.join(tmp, "hidden-one"),
            "source": "builtin",
            "disableModelInvocation": True,
        };
        block = format_skills_for_prompt([visible, hidden]);
        assert "<available_skills>" in block and "</available_skills>" in block;
        assert "<name>escaper</name>" in block;
        assert "&lt;b &amp; c&gt;d &quot;quotes&quot; and &apos;apos&apos;" in block;
        assert "hidden-one" not in block;

        # Catalog preamble wording matches the legacy contract.
        assert "Use the read tool to load a skill's file" in block;
        assert "resolve it against the skill directory" in block;

        assert format_skills_for_prompt([]) == "";
        assert format_skills_for_prompt([hidden]) == "";

        base = "SYSTEM PROMPT";
        assert append_skills_to_prompt(base, [visible]) == base + block;
        assert append_skills_to_prompt(base, []) == base;
    } finally {
        _cleanup(tmp);
    }
}


test "expand_skill_command inlines the referenced skill body" {
    tmp = _make_tmp();
    try {
        dir_path = os.path.join(tmp, "demo");
        path = _write_skill(dir_path, "demo", "Demo skill.", body="Step 1. Step 2.");
        skill: dict = {
            "name": "demo",
            "description": "Demo skill.",
            "filePath": path,
            "baseDir": dir_path,
            "source": "builtin",
            "disableModelInvocation": False,
        };
        expanded = expand_skill_command("/skill:demo please run it", [skill]);
        assert '<skill name="demo" location="' + path + '">' in expanded;
        assert "References are relative to " + dir_path + "." in expanded;
        assert "Step 1. Step 2." in expanded;
        assert "</skill>\n\nplease run it" in expanded;

        # Without args there is no trailing blank-arg section.
        bare = expand_skill_command("/skill:demo", [skill]);
        assert bare.endswith("</skill>");

        # Unknown skill, non-command input, and unreadable files all pass
        # the original text straight through.
        assert expand_skill_command("/skill:nope hi", [skill]) == "/skill:nope hi";
        assert expand_skill_command("just chat", [skill]) == "just chat";
        broken: dict = dict(skill);
        broken["filePath"] = os.path.join(tmp, "gone", "SKILL.md");
        assert expand_skill_command("/skill:demo x", [broken]) == "/skill:demo x";
    } finally {
        _cleanup(tmp);
    }
}


test "load_skill_by_dir returns stripped bodies and empty on misses" {
    tmp = _make_tmp();
    try {
        _write_skill(os.path.join(tmp, "pi", "skills", "realone"), "realone",
                     "Real one.", body="Real body here.");
        assert load_skill_by_dir("realone", package_root=tmp) == "Real body here.";
        assert load_skill_by_dir("missing", package_root=tmp) == "";
        # Corrupt bytes fall back to '' instead of raising.
        _write_bytes_as_latin1(os.path.join(tmp, "pi", "skills", "corrupt", "SKILL.md"),
                               "\xff\xfe\x00\xff");
        assert load_skill_by_dir("corrupt", package_root=tmp) == "";
    } finally {
        _cleanup(tmp);
    }
}


test "skill_read_allowlist yields absolute files and rooted base dirs" {
    tmp = _make_tmp();
    try {
        p1 = _write_skill(os.path.join(tmp, "one"), "one", "One.");
        p2 = _write_skill(os.path.join(tmp, "two"), "two", "Two.");
        skills: list = [
            {"name": "one", "description": "One.", "filePath": p1,
             "baseDir": _dir_name(p1), "source": "builtin",
             "disableModelInvocation": False},
            {"name": "two", "description": "Two.", "filePath": p2,
             "baseDir": _dir_name(p2), "source": "user",
             "disableModelInvocation": True},
        ];
        allow = skill_read_allowlist(skills);
        files: list = allow["files"];
        roots: list = allow["roots"];
        assert files == [p1, p2];
        assert roots == [_dir_name(p1) + os.sep, _dir_name(p2) + os.sep];
    } finally {
        _cleanup(tmp);
    }
}


test "real jackal catalog under pi/skills parses read-only" {
    # Locate the repo root by walking up from the cwd looking for pi/skills.
    probe = os.getcwd();
    repo = "";
    for _hop in range(8) {
        if os.path.isdir(os.path.join(probe, "pi", "skills")) {
            repo = probe;
            break;
        }
        parent = _dir_name(probe);
        if parent == probe {
            break;
        }
        probe = parent;
    }
    if not repo {
        # Repo layout unavailable in this environment; nothing to assert.
        return;
    }
    tmp = _make_tmp();
    try {
        # Read-only smoke: real builtin catalog, empty user/home roots, cwd
        # pointed away from any project skills dir.
        result = load_jackal_skills(
            cwd=tmp, package_root=repo,
            agent_dir=os.path.join(tmp, "home"),
        );
        items: list = result["skills"];
        # The repo ships ~26 built-in skills; be robust to small drift.
        assert len(items) >= 20;
        prev = "";
        for item in items {
            s: dict = item;
            name = str(s["name"]);
            desc = str(s["description"]);
            assert name != "";
            assert desc != "";
            assert os.path.isfile(str(s["filePath"]));
            assert str(s["filePath"]).startswith(os.path.join(repo, "pi", "skills"));
            assert str(s["source"]) == "builtin";
            if prev {
                assert prev <= name;  # name-sorted output
            }
            prev = name;
        }
    } finally {
        _cleanup(tmp);
    }
}
