"""Prompt context expansion and project-file picker data."""
import os;
import re;
import from tui.state {
    LiveShell, _QUOTED_MENTION_PATTERN, _EXPLORER_SKIP_DIRS,
    _EXPLORER_MAX_FILES, _EXPLORER_MAX_DEPTH,
}
import from agent.context_input {
    expand_context_input, is_valid_file_path, parse_line_range, _load_file_slice,
}
import from agent.skills { _load_ignore_rules, _match_ignore_pattern }
import from tui.picker_base { _open_picker }

"""EXPLORER picker rows via a bounded recursive walk under cwd.

Dot-dirs and _EXPLORER_SKIP_DIRS are skipped (dot-FILES stay selectable);
gitignore-style rules from .gitignore/.ignore/.fdignore are honored via
agent.skills helpers; depth/file caps keep huge trees responsive. Rows are
cwd-relative forward-slash paths; ids map 1:1 for toggling. Pure over cwd
— replicated in tui/overlays.test.jac (keep in sync)."""
def _explorer_walk(dir_path: str, base_root: str, depth: int, out: list[str]) {
    if depth > _EXPLORER_MAX_DEPTH or len(out) >= _EXPLORER_MAX_FILES {
        return;
    }
    rules: list = [];
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


def _explorer_file_entries(cwd: str) -> dict {
    out: list[str] = [];
    _explorer_walk(cwd, cwd, 1, out);
    return {"rows": list(out), "ids": list(out)};
}


"""SKILLS picker rows from a load_jackal_skills() result's skill list: one
"name — description" row per skill (model-hidden skills tagged "· hidden");
ids are skill names so enter can insert /skill:name. Pure over its input
— replicated in tui/overlays.test.jac."""
def _skills_picker_entries(skills: list) -> dict {
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


"""Editor-draft mention text for picked paths: deduped `@a @b ` with a
trailing space so typing continues cleanly. Paths containing whitespace
use the quoted `@"a b.txt"` form, which the TUI-side pre-pass expands
(see _take_quoted_mentions); bare paths stay unquoted for readability.
Empty picks -> ""."""
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


"""Extract @\"path\" / @\"path:N[-M]\" mentions (whitespace-tolerant form).

Returns (remaining_text, mentions); each mention is a dict with keys
raw / path / start / end / line_range. A :N or :N-M line range is
consumed when it appears inside OR after the closing quote and parses;
otherwise it stays part of the path. Paths failing
agent.context_input's validity check are LEFT in the text untouched (no
silent deletion of user text). Pure over its input — replicated in
tui/overlays.test.jac (keep in sync).

Ownership note: this pre-pass exists because the shared parser
(agent.context_input._FILE_MENTION_PATTERN) tokenizes on whitespace; the
quoting-aware regex belongs there once that file is editable by this
task's scope."""
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


"""Expand user text INCLUDING the quoted-mention form.

Thin wrapper over expand_context_input: quoted mentions are lifted out
first, their <file> blocks are loaded via context_input's own slice
loader (so truncation/range/error semantics match exactly), and the
remaining text goes through the normal expansion (plain @mentions and
!cmd still work alongside). Blocks are appended under an
"Attached context:" header — merged into the existing section when the
base expansion already produced one."""
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


"""Append text to the prompt draft (picker/skill insertion point moves to
the end; manual edits drop history-browse mode as editor_insert does)."""
def _insert_into_draft(app: LiveShell, addition: str) {
    if not addition {
        return;
    }
    draft = app.shell.prompt.draft + addition;
    app.shell.prompt.draft = draft;
    app.shell.prompt.caret = len(draft);
    app.shell.prompt.history_index = -1;
    app.dirty = True;
}


"""Open the EXPLORER multi-select overlay over the project tree."""
def _open_explorer_picker(app: LiveShell) -> str {
    entries = _explorer_file_entries(os.getcwd());
    if not entries["rows"] {
        return "no readable project files";
    }
    opened = _open_picker(app, "EXPLORER", entries["rows"], entries["ids"], multi=True);
    if not opened {
        return "picker unavailable (overlay busy)";
    }
    return "";
}
