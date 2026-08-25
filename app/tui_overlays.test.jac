"""Tasks/checkpoints/explorer/skills overlay row builders for tui.jac.

tui.jac cannot be imported headless (its `with entry` TTY guard raises
SystemExit(1) under `jac test` — same constraint as keybinding_probe), so
this file REPLICATES the pure picker-entry builders verbatim:
_task_picker_entries, _checkpoint_picker_entries, plus the newer
_explorer_file_entries / _skills_picker_entries / _format_mentions wiring.
Everything BEHIND them is real: agent.tasks / agent.checkpoints /
agent.skills loaders (load_skills_from_dir) run against a temp project dir.
Keep the replicas in sync with app/tui.jac.
"""

import os;
import re;
import tempfile;
import shutil;
import json;

import from ui.width { display_width, truncate_text }
import from agent.tasks {
    load_tasks,
    format_tasks_list,
    task_counts,
    add_task,
}
import from agent.checkpoints {
    create_checkpoint,
    list_checkpoints,
    format_checkpoint_overlay_row,
}
import from agent.skills {
    load_skills_from_dir,
    _load_ignore_rules,
    _match_ignore_pattern,
}
import from agent.context_input {
    expand_context_input,
    is_valid_file_path,
    parse_line_range,
    _load_file_slice,
}
import from agent.compaction { load_project_config }


# --- verbatim replica of tui.jac _meter ---------------------------------

def _meter(value: float, width: int) -> str {
    if width < 3 {
        return "▪" * max(0, width);
    }
    inner = width - 2;
    filled = int(max(0.0, min(1.0, value)) * float(inner));
    if filled > inner {
        filled = inner;
    }
    return "▐" + ("█" * filled) + ("░" * (inner - filled)) + "▌";
}


# --- verbatim replicas of tui.jac picker entry builders ------------------

def _task_picker_entries(cwd: str) -> dict[str, list[str]] {
    tasks: list[dict[str, any]] = load_tasks(cwd);
    if not tasks {
        return {"rows": ["No tasks yet."], "ids": ["__header__"]};
    }
    counts = task_counts(tasks);
    total: int = int(counts["pending"]) + int(counts["in_progress"]) + int(counts["completed"]);
    ratio: float = float(counts["completed"]) / float(total) if total else 0.0;
    rows: list[str] = [
        str(total) + " tasks  " + _meter(ratio, 14) + "  "
        + str(counts["completed"]) + "/" + str(total) + " done"
    ];
    ids: list[str] = ["__header__"];
    idx = 0;
    for ln in format_tasks_list(tasks).split("\n") {
        rows.append(ln);
        # First two board lines are the counts header and divider rule;
        # everything after maps back onto its task index for enter.
        if idx >= 2 {
            ids.append(str(idx - 2));
        } else {
            ids.append("__header__");
        }
        idx += 1;
    }
    return {"rows": rows, "ids": ids};
}


def _checkpoint_picker_entries(cwd: str) -> dict[str, list[str]] {
    items: list[dict[str, any]] = list_checkpoints(cwd);
    rows: list[str] = [];
    ids: list[str] = [];
    for item in items[:20] {
        rows.append(format_checkpoint_overlay_row(item));
        ids.append(str(item.get("name", "")));
    }
    return {"rows": rows, "ids": ids};
}


# --- verbatim replica of tui.jac explorer/skills builders -----------------

glob _EXPLORER_SKIP_DIRS: list[str] = [
         "node_modules", "__pycache__", ".git", ".jac", ".jackal",
         ".venv", "venv", ".mypy_cache", ".pytest_cache",
     ],
     _EXPLORER_MAX_FILES: int = 400,
     _EXPLORER_MAX_DEPTH: int = 6;


def _explorer_walk(dir_path: str, base_root: str, depth: int, out: list[str]) {
    if depth > _EXPLORER_MAX_DEPTH or len(out) >= _EXPLORER_MAX_FILES {
        return;
    }
    rules: list[any] = [];
    try {
        rules = _load_ignore_rules(base_root, dir_path);
    } except Exception {
        rules = [];
    }
    try {
        entries = sorted(os.listdir(dir_path));
    } except OSError {
        return;
    }
    subdirs: list[str] = [];
    for name in entries {
        full = os.path.join(dir_path, name);
        is_dir = os.path.isdir(full);
        rel_fn: any = os.path.relpath;
        rel = str(rel_fn(full, base_root)).replace(os.sep, "/");
        # Ignore patterns match dirs with a trailing slash (skills.jac
        # convention), files bare.
        rel_cmp = rel + "/" if is_dir else rel;
        try {
            if _match_ignore_pattern(rel_cmp, rules) {
                continue;
            }
        } except Exception {
        }
        if is_dir {
            if name.startswith(".") or name in _EXPLORER_SKIP_DIRS {
                continue;
            }
            subdirs.append(name);
        } else {
            if len(out) < _EXPLORER_MAX_FILES {
                out.append(rel);
            }
        }
    }
    for name in subdirs {
        _explorer_walk(os.path.join(dir_path, name), base_root, depth + 1, out);
        if len(out) >= _EXPLORER_MAX_FILES {
            return;
        }
    }
}


def _explorer_file_entries(cwd: str) -> dict[str, list[str]] {
    out: list[str] = [];
    _explorer_walk(cwd, cwd, 1, out);
    return {"rows": list(out), "ids": list(out)};
}


def _skills_picker_entries(skills: list[dict[str, any]]) -> dict[str, list[str]] {
    if not skills {
        return {"rows": ["no skills found"], "ids": ["__header__"]};
    }
    rows: list[str] = [];
    ids: list[str] = [];
    for s in skills {
        name = str(s.get("name", ""));
        desc = str(s.get("description", ""));
        label = name + (" — " + desc if desc else "");
        if s.get("disableModelInvocation", False) is True {
            label += "  · hidden";
        }
        rows.append(label);
        ids.append(name);
    }
    return {"rows": rows, "ids": ids};
}


def _format_mentions(paths: list) -> str {
    parts: list[str] = [];
    seen: set[str] = set();
    for p in paths {
        rel = str(p);
        if not rel or rel in seen {
            continue;
        }
        seen.add(rel);
        if re.search(r"\s", rel) is not None {
            parts.append("@\"" + rel + "\"");
        } else {
            parts.append("@" + rel);
        }
    }
    if not parts {
        return "";
    }
    return " ".join(parts) + " ";
}


# --- verbatim replicas of tui.jac mode/filter/quote/mcp helpers -----------

# Quoted mention: @"path" / @"path:N[-M]" / @"path":N[-M] — an optional
# line range is accepted inside OR after the closing quote.
glob _QUOTED_MENTION_PATTERN: str = r'@"([^"]+)"(?::(\d+)(?:-(\d+))?)?';


def _mode_badge(mode: str) -> str {
    if mode == "normal" {
        return "";
    }
    if mode == "auto-accept" {
        return " AUTO ";
    }
    if mode == "yolo" {
        return " YOLO ";
    }
    if mode == "plan" {
        return " PLAN ";
    }
    if mode == "ask" {
        return " ASK ";
    }
    return " " + mode.upper() + " ";
}


def _multi_filtered(p: dict) -> tuple[list, list] {
    options: list = list(p.get("options", []));
    ids: list = list(p.get("ids", []));
    filt: str = str(p.get("filter", "")).strip().lower();
    if not filt {
        return (options, ids);
    }
    vis_options: list = [];
    vis_ids: list = [];
    for i in range(len(options)) {
        if filt in str(options[i]).lower() {
            vis_options.append(options[i]);
            vis_ids.append(str(ids[i]) if i < len(ids) else "");
        }
    }
    return (vis_options, vis_ids);
}


def _take_quoted_mentions(text: str) -> tuple[str, list[dict]] {
    mentions: list[dict] = [];
    spans: list[tuple[int, int]] = [];
    for m in re.finditer(_QUOTED_MENTION_PATTERN, text) {
        inner: str = str(m.group(1));
        path_part: str = inner;
        rng: dict | None = None;
        outer_start: any = m.group(2);
        outer_end: any = m.group(3);
        if outer_start {
            # Range AFTER the closing quote: @"path":10-20.
            outer_range: str = str(outer_start) + (
                "-" + str(outer_end) if outer_end else ""
            );
            parsed_outer: dict | None = parse_line_range(outer_range);
            if parsed_outer is not None {
                rng = parsed_outer;
            }
            # A malformed outer range keeps the quoted content as the path;
            # the bad suffix disappears with the token span.
        } else {
            cm = re.search(r":(\d+)(?:-(\d+))?$", inner);
            if cm is not None {
                inner_range: str = inner[cm.start() + 1:];
                parsed_inner: dict | None = parse_line_range(inner_range);
                if parsed_inner is not None {
                    path_part = inner[:cm.start()];
                    rng = parsed_inner;
                }
            }
        }
        if not is_valid_file_path(path_part) {
            continue;
        }
        spans.append((m.start(), m.end()));
        mentions.append({
            "raw": str(m.group(0)),
            "path": path_part,
            "start": m.start(),
            "end": m.end(),
            "line_range": rng,
        });
    }
    if not mentions {
        return (text, []);
    }
    parts: list[str] = [];
    last: int = 0;
    for sp in spans {
        parts.append(text[last:sp[0]]);
        last = sp[1];
    }
    parts.append(text[last:]);
    return ("".join(parts), mentions);
}


def _expand_quoted_context(cwd: str, text: str) -> str {
    lifted: tuple[str, list[dict]] = _take_quoted_mentions(text);
    cleaned: str = lifted[0];
    quotes: list[dict] = lifted[1];
    if not quotes {
        return expand_context_input(cwd, text);
    }
    base: str = "";
    body: str = cleaned.strip();
    if body {
        try {
            base = expand_context_input(cwd, body);
        } except Exception {
            base = body;
        }
    }
    blocks: list[str] = [];
    for q in quotes {
        qpath: str = str(q.get("path", ""));
        qrng: any = q.get("line_range");
        try {
            got: tuple[str, int] = _load_file_slice(cwd, qpath, qrng);
            blocks.append(got[0]);
        } except (OSError, ValueError) as exc {
            blocks.append('<file path="' + qpath + '" error="' + str(exc) + '" />');
        }
    }
    if "Attached context:" in base {
        return base + "\n" + "\n".join(blocks);
    }
    head: str = base + "\n\n" if base else "";
    return head + "Attached context:\n" + "\n".join(blocks);
}


def _local_mcp_server_specs(cfg: dict) -> dict[str, list[str]] {
    out: dict[str, list[str]] = {};
    raw: any = cfg.get("mcp") if isinstance(cfg, dict) else None;
    if not isinstance(raw, dict) {
        return out;
    }
    servers: any = raw.get("servers");
    if not isinstance(servers, dict) {
        return out;
    }
    for (name, ent) in servers.items() {
        if not isinstance(ent, dict) or not str(name) {
            continue;
        }
        cmd: any = ent.get("command");
        if isinstance(cmd, str) {
            cmd = [cmd];
        }
        if not isinstance(cmd, list) or not cmd {
            continue;
        }
        parts: list[str] = [str(c) for c in cmd];
        extra: any = ent.get("args");
        if isinstance(extra, list) {
            parts.extend([str(a) for a in extra]);
        }
        out[str(name)] = parts;
    }
    return out;
}


def _mcp_status_entries(cwd: str, clients: dict) -> dict {
    specs: dict[str, list[str]] = {};
    try {
        cfg: dict = load_project_config(cwd);
        parsed: dict[str, list[str]] = _local_mcp_server_specs(cfg);
        specs = parsed;
    } except Exception {
        specs = {};
    }
    rows: list[str] = [];
    ids: list[str] = [];
    declared: set[str] = set();
    for name in sorted(specs) {
        sname: str = str(name);
        declared.add(sname);
        cmd_label: str = " ".join(specs[name]);
        client: any = clients.get(sname);
        if client is not None and client.initialized is True {
            rows.append(sname + " — connected · " + cmd_label);
        } elif client is not None {
            rows.append(sname + " — spawn failed · " + cmd_label);
        } else {
            rows.append(sname + " — configured · not connected · " + cmd_label);
        }
        ids.append("__header__");
    }
    for cname in sorted(clients) {
        if str(cname) in declared {
            continue;
        }
        rows.append(str(cname) + " — attached (not in .jackal config)");
        ids.append("__header__");
    }
    if not rows {
        rows.append("no mcp servers configured (.jackal: \"mcp\": {\"servers\": …})");
        ids.append("__header__");
    }
    return {"rows": rows, "ids": ids};
}


# --- fixtures ------------------------------------------------------------

def _make_project -> str {
    return tempfile.mkdtemp(prefix="jackal-tui-overlays-");
}


def _seed_task_file(cwd: str, tasks: list[dict[str, any]]) {
    os.makedirs(os.path.join(cwd, ".jackal"), exist_ok=True);
    fh = open(os.path.join(cwd, ".jackal", "tasks.json"), "w");
    json.dump(tasks, fh);
    fh.close();
}


# --- tests ----------------------------------------------------------------

test "empty project yields single non-selectable header row" {
    cwd = _make_project();
    try {
        entries = _task_picker_entries(cwd);
        assert entries["rows"] == ["No tasks yet."];
        assert entries["ids"] == ["__header__"];
        assert _checkpoint_picker_entries(cwd)["rows"] == [];
    } finally {
        shutil.rmtree(cwd, ignore_errors=True);
    }
}

test "task board maps selectable ids onto task indices" {
    cwd = _make_project();
    try {
        add_task(cwd, "first thing");
        add_task(cwd, "second thing", "with a blurb");
        # Mark the first completed via a raw rewrite (update_tasks not
        # imported to keep this fixture minimal).
        seeded: list[dict[str, any]] = [];
        for i in range(len(load_tasks(cwd))) {
            t = dict(load_tasks(cwd)[i]);
            if i == 0 {
                t["status"] = "completed";
                t["completedAt"] = str(t.get("createdAt"));
            }
            seeded.append(t);
        }
        _seed_task_file(cwd, seeded);

        entries = _task_picker_entries(cwd);
        # summary + counts header + divider + one row per task
        assert len(entries["rows"]) == 3 + len(seeded);
        assert entries["ids"][0] == "__header__";
        assert entries["ids"][1] == "__header__";
        assert entries["ids"][2] == "__header__";
        assert entries["ids"][3] == "0";
        assert entries["ids"][4] == "1";
        # Meter summary reflects the one completed task.
        assert "█" in entries["rows"][0];
        assert "1/2 done" in entries["rows"][0];
        # Task rows carry the store's own formatting (icon, id, title).
        assert "✓" in entries["rows"][3];
        assert "second thing" in entries["rows"][4];
        assert "— with a blurb" in entries["rows"][4];
    } finally {
        shutil.rmtree(cwd, ignore_errors=True);
    }
}

test "checkpoint entries expose newest-first names with overlay rows" {
    cwd = _make_project();
    try {
        meta_old = create_checkpoint(
            cwd, [{"role": "user", "content": "hello"}],
            "mock", "mockllm", name="cp-old", modified_files=[],
        );
        meta_new = create_checkpoint(
            cwd, [], "mock", "mockllm", name="cp-new", modified_files=[],
        );
        assert meta_old["name"] == "cp-old";
        assert meta_new["name"] == "cp-new";

        entries = _checkpoint_picker_entries(cwd);
        assert len(entries["rows"]) == 2;
        # Newest timestamp first; ids map 1:1 onto picker actions.
        assert entries["ids"] == ["cp-new", "cp-old"];
        assert "cp-new" in entries["rows"][0];
        assert "0 msgs" in entries["rows"][0];
        assert "0 files" in entries["rows"][0];
    } finally {
        shutil.rmtree(cwd, ignore_errors=True);
    }
}


def _touch(cwd: str, rel: str) {
    full: str = os.path.join(cwd, rel);
    dir_fn: any = os.path.dirname;
    parent: str = str(dir_fn(full));
    if parent {
        os.makedirs(parent, exist_ok=True);
    }
    fh = open(full, "w");
    fh.write("x");
    fh.close();
}


def _seed_skill(cwd: str, dir_name: str, name: str, description: str, hidden: bool = False) {
    sk_dir = os.path.join(cwd, ".jackal", "skills", dir_name);
    os.makedirs(sk_dir, exist_ok=True);
    fm = "---\nname: " + name + "\ndescription: " + description + "\n";
    if hidden {
        fm += "disable-model-invocation: true\n";
    }
    fm += "---\nBody.\n";
    fh = open(os.path.join(sk_dir, "SKILL.md"), "w");
    fh.write(fm);
    fh.close();
}


# --- explorer / skills / mention tests ------------------------------------

test "explorer walk skips junk dirs and honors gitignore" {
    cwd = _make_project();
    try {
        os.makedirs(os.path.join(cwd, "sub"));
        os.makedirs(os.path.join(cwd, "node_modules", "pkg"));
        os.makedirs(os.path.join(cwd, "__pycache__"));
        os.makedirs(os.path.join(cwd, ".git"));
        _touch(cwd, ".gitignore");
        _touch(cwd, ".hidden-file");
        _touch(cwd, "a.txt");
        _touch(cwd, "ignored.txt");
        _touch(cwd, os.path.join("sub", "b.py"));
        _touch(cwd, os.path.join("node_modules", "pkg", "x.js"));
        gh = open(os.path.join(cwd, ".gitignore"), "w");
        gh.write("ignored.txt\n");
        gh.close();

        entries = _explorer_file_entries(cwd);
        # Dot-FILES stay selectable; dot-dirs and skip-listed dirs do not;
        # gitignore'd files are excluded. ids map 1:1 onto rows.
        assert entries["rows"] == [".gitignore", ".hidden-file", "a.txt", "sub/b.py"];
        assert entries["ids"] == entries["rows"];
    } finally {
        shutil.rmtree(cwd, ignore_errors=True);
    }
}

test "explorer walk enforces depth and file caps" {
    cwd = _make_project();
    try {
        deep = "";
        for i in range(8) {
            deep = os.path.join(deep, "d" + str(i)) if deep else "d0";
            _touch(cwd, os.path.join(deep, "leaf.txt"));
        }
        for j in range(5) {
            _touch(cwd, "f" + str(j) + ".txt");
        }
        entries = _explorer_file_entries(cwd);
        # Depth cap (6): leaves under d0..d4 survive the walk (root=1,
        # d0=2 ... d4=6), d5+ branches are cut. Plus the 5 root files.
        assert len(entries["rows"]) == 10;
        rows: list[str] = entries["rows"];
        for r in rows {
            assert "d5" not in r and "d6" not in r;
        }
    } finally {
        shutil.rmtree(cwd, ignore_errors=True);
    }
}

test "skills picker lists project skills with hidden tagging" {
    cwd = _make_project();
    try {
        entries = _skills_picker_entries([]);
        assert entries["rows"] == ["no skills found"];
        assert entries["ids"] == ["__header__"];

        _seed_skill(cwd, "my-skill", "my-skill", "does things well");
        _seed_skill(cwd, "quiet-skill", "quiet-skill", "hidden helper", hidden=True);

        # Real loader: parse the seeded project skills dir, then format.
        loaded: dict[str, any] = load_skills_from_dir(
            os.path.join(cwd, ".jackal", "skills"), "project"
        );
        assert len(loaded["skills"]) == 2;

        entries = _skills_picker_entries(loaded["skills"]);
        # Name-sorted by the loader; ids are skill names so enter can
        # insert /skill:name.
        assert entries["ids"] == ["my-skill", "quiet-skill"];
        assert entries["rows"][0] == "my-skill — does things well";
        assert "quiet-skill — hidden helper" in entries["rows"][1];
        assert "· hidden" in entries["rows"][1];
    } finally {
        shutil.rmtree(cwd, ignore_errors=True);
    }
}

test "mention formatting dedupes and trails a space" {
    assert _format_mentions([]) == "";
    got = _format_mentions(["a.py", "sub/b.py", "a.py"]);
    assert got == "@a.py @sub/b.py ";
}


# --- mode badge / explorer filter / quoted mention / mcp status tests ------

test "mode badge is empty for normal and loud for read-only modes" {
    assert _mode_badge("normal") == "";
    assert _mode_badge("auto-accept") == " AUTO ";
    assert _mode_badge("yolo") == " YOLO ";
    assert _mode_badge("plan") == " PLAN ";
    assert _mode_badge("ask") == " ASK ";
    # Unknown modes still surface (uppercased), never silently hidden.
    assert _mode_badge("wat") == " WAT ";
}

test "multi filter narrows rows case-insensitively with aligned ids" {
    p: dict = {
        "options": ["src/main.py", "README.md", "src/SUB/Deep.txt"],
        "ids": ["src/main.py", "README.md", "src/SUB/Deep.txt"],
        "filter": "",
    };
    full: tuple[list, list] = _multi_filtered(p);
    assert len(full[0]) == 3;

    p["filter"] = "PY";
    got: tuple[list, list] = _multi_filtered(p);
    assert got[0] == ["src/main.py"];
    assert got[1] == ["src/main.py"];

    # Substring anywhere in the path, not just the basename.
    p["filter"] = "deep";
    got2: tuple[list, list] = _multi_filtered(p);
    assert got2[0] == ["src/SUB/Deep.txt"];

    p["filter"] = "zzz";
    got3: tuple[list, list] = _multi_filtered(p);
    assert got3[0] == [];
    assert got3[1] == [];
}

test "quoted mentions extract paths with spaces and line ranges" {
    # Plain quoted path.
    r1: tuple[str, list[dict]] = _take_quoted_mentions('see @"my file.md" now');
    assert len(r1[1]) == 1;
    assert r1[1][0]["path"] == "my file.md";
    assert r1[1][0]["line_range"] is None;
    assert r1[0] == "see  now";

    # Range inside the quotes.
    r2: tuple[str, list[dict]] = _take_quoted_mentions('@"notes big.txt:10-20"');
    assert len(r2[1]) == 1;
    assert r2[1][0]["path"] == "notes big.txt";
    assert r2[1][0]["line_range"] == {"start": 10, "end": 20};

    # Range after the closing quote works too.
    r2b: tuple[str, list[dict]] = _take_quoted_mentions('see @"other file.md":3');
    assert len(r2b[1]) == 1;
    assert r2b[1][0]["path"] == "other file.md";
    assert r2b[1][0]["line_range"] == {"start": 3};
    assert r2b[0] == "see ";

    # Malformed range inside the quotes stays part of the path.
    r3: tuple[str, list[dict]] = _take_quoted_mentions('@"weird:name.txt:abc"');
    assert len(r3[1]) == 1;
    assert r3[1][0]["path"] == "weird:name.txt:abc";

    # Invalid (traversal) paths are left untouched in the text.
    r4: tuple[str, list[dict]] = _take_quoted_mentions('@"../escape.md"');
    assert r4[1] == [];
    assert r4[0] == '@"../escape.md"';

    # No quoted mentions -> verbatim passthrough.
    r5: tuple[str, list[dict]] = _take_quoted_mentions("plain @a.py text");
    assert r5[0] == "plain @a.py text";
    assert r5[1] == [];
}

test "quoted context expansion attaches real file slices" {
    cwd = _make_project();
    try {
        body = "alpha line\nbeta line\ngamma line";
        fh = open(os.path.join(cwd, "my file.md"), "w");
        fh.write(body);
        fh.close();

        out: str = _expand_quoted_context(cwd, 'review @"my file.md":2-2 please');
        assert '<file path="my file.md:2">' in out;
        assert "beta line" in out;
        assert "gamma line" not in out;
        assert 'review  please' in out;
        assert "Attached context:" in out;

        # Missing quoted file degrades to an error block, not a crash.
        out2: str = _expand_quoted_context(cwd, '@"nope missing.txt"');
        assert 'error=' in out2;
        assert 'Attached context:' in out2;

        # No quotes at all -> plain expansion passthrough.
        out3: str = _expand_quoted_context(cwd, "just words");
        assert out3 == "just words";
    } finally {
        shutil.rmtree(cwd, ignore_errors=True);
    }
}

obj FakeMcpClient {
    has initialized: bool = False;
}

test "mcp status reports config honestly without live connections" {
    cwd = _make_project();
    try {
        # Config lives in a FILE named ".jackal" (walk-up loader).
        cfg = {"mcp": {"servers": {
            "zeta": {"command": ["jac", "mcp"]},
            "alpha": {"command": "toolserv"},
        }}};
        fh = open(os.path.join(cwd, ".jackal"), "w");
        json.dump(cfg, fh);
        fh.close();

        entries = _mcp_status_entries(cwd, {});
        assert entries["ids"] == ["__header__", "__header__"];
        # Sorted by name; string-form command is normalized to argv.
        assert entries["rows"][0].startswith("alpha — configured · not connected · toolserv");
        assert entries["rows"][1].startswith("zeta — configured · not connected · jac mcp");

        # A handshaked client flips its row to connected; an attached
        # client absent from config gets its own undeclared row.
        ok_client = FakeMcpClient(initialized=True);
        entries2 = _mcp_status_entries(
            cwd, {"zeta": ok_client, "ghost": FakeMcpClient()}
        );
        assert "zeta — connected · jac mcp" in entries2["rows"];
        assert "ghost — attached (not in .jackal config)" in entries2["rows"];
        # alpha stays honest: configured but never spawned.
        rows2: list[str] = [str(r) for r in entries2["rows"]];
        assert any(
            r.startswith("alpha — configured · not connected")
            for r in rows2
        );
    } finally {
        shutil.rmtree(cwd, ignore_errors=True);
    }
}

test "mcp status empty state names the config convention" {
    cwd = _make_project();
    try {
        entries = _mcp_status_entries(cwd, {});
        assert len(entries["rows"]) == 1;
        assert "no mcp servers configured" in entries["rows"][0];
        assert "__header__" in entries["ids"];
    } finally {
        shutil.rmtree(cwd, ignore_errors=True);
    }
}
