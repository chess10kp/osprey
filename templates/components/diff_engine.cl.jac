"""Git unified-diff engine — parse hunks, navigate, accept/reject, write files."""

import re;
import os;
import tempfile;
import from child_process { execSync, spawnSync }
import from pathlib { Path }


def strip_ansi(text: str) -> str {
    if not text {
        return "";
    }
    return re.sub(r"\x1b\[[0-9;]*m", "", text);
}


def:pub get_terminal_width() -> int {
    try {
        sz: any = os.get_terminal_size();
        return max(40, int(sz.columns) - 4);
    } except Exception {
        return 96;
    }
}


def:pub truncate_to_width(text: str, max_w: int) -> str {
    if max_w <= 0 {
        return "";
    }
    plain: str = strip_ansi(text);
    if len(plain) <= max_w {
        return text;
    }
    if max_w <= 1 {
        return plain[0:max_w];
    }
    return plain[0 : max_w - 1] + "…";
}


def inline_spans(old_line: str, new_line: str) -> list {
    if old_line == new_line {
        if not old_line {
            return [];
        }
        return [{"text": old_line, "kind": "same"}];
    }
    pre: int = 0;
    olen: int = len(old_line);
    nlen: int = len(new_line);
    while pre < olen and pre < nlen and old_line[pre] == new_line[pre] {
        pre += 1;
    }
    suf: int = 0;
    while (
        suf < (olen - pre)
        and suf < (nlen - pre)
        and old_line[olen - 1 - suf] == new_line[nlen - 1 - suf]
    ) {
        suf += 1;
    }
    out: list = [];
    if pre > 0 {
        out.append({"text": old_line[0:pre], "kind": "same"});
    }
    mid_old: str = old_line[pre : olen - suf];
    mid_new: str = new_line[pre : nlen - suf];
    if mid_old and mid_new {
        out.extend(_diff_middle(mid_old, mid_new));
    } elif mid_old {
        out.append({"text": mid_old, "kind": "remove"});
    } elif mid_new {
        out.append({"text": mid_new, "kind": "add"});
    }
    if suf > 0 {
        out.append({"text": old_line[olen - suf : olen], "kind": "same"});
    }
    return _merge_adjacent(out);
}


def _diff_middle(old_line: str, new_line: str) -> list {
    if not old_line and not new_line {
        return [];
    }
    if not old_line {
        return [{"text": new_line, "kind": "add"}];
    }
    if not new_line {
        return [{"text": old_line, "kind": "remove"}];
    }
    out: list = [];
    i: int = 0;
    j: int = 0;
    while i < len(old_line) and j < len(new_line) {
        if old_line[i] == new_line[j] {
            out.append({"text": old_line[i], "kind": "same"});
            i += 1;
            j += 1;
        } else {
            out.append({"text": old_line[i], "kind": "remove"});
            out.append({"text": new_line[j], "kind": "add"});
            i += 1;
            j += 1;
        }
    }
    while i < len(old_line) {
        out.append({"text": old_line[i], "kind": "remove"});
        i += 1;
    }
    while j < len(new_line) {
        out.append({"text": new_line[j], "kind": "add"});
        j += 1;
    }
    return _merge_adjacent(out);
}


def _merge_adjacent(spans: list) -> list {
    if not spans {
        return [];
    }
    out: list = [];
    cur: any = {"text": spans[0]["text"], "kind": spans[0]["kind"]};
    for i in range(1, len(spans)) {
        s: any = spans[i];
        if s["kind"] == cur["kind"] {
            cur["text"] = str(cur["text"]) + str(s["text"]);
        } else {
            out.append(cur);
            cur = {"text": s["text"], "kind": s["kind"]};
        }
    }
    out.append(cur);
    return out;
}


def max_rows_per_file() -> int {
    return 400;
}


def hunk_key(file_path: str, hunk_index: int) -> str {
    return file_path + "#" + str(hunk_index);
}


def parse_multi_file_patch(patch: str) -> any {
    files: list = [];
    rows_by_file: any = {};
    hunks_by_file: any = {};
    if not patch or not patch.strip() {
        return {
            "files": files,
            "rows_by_file": rows_by_file,
            "hunks_by_file": hunks_by_file,
        };
    }
    chunks: list = _split_file_chunks(patch);
    for chunk_raw in chunks {
        chunk: str = str(chunk_raw);
        parsed: any = _parse_one_file(chunk);
        path: str = "";
        if parsed and "path" in parsed {
            path = str(parsed["path"]);
        }
        if not path {
            continue;
        }
        files.append(path);
        rows_by_file[path] = parsed["rows"];
        hunks_by_file[path] = parsed["hunks"];
    }
    return {
        "files": files,
        "rows_by_file": rows_by_file,
        "hunks_by_file": hunks_by_file,
    };
}


def _split_file_chunks(patch: str) -> list {
    lines: list = patch.split("\n");
    chunks: list = [];
    cur: list = [];
    for line_raw in lines {
        line: str = str(line_raw);
        if line.startswith("diff --git ") and cur {
            chunks.append("\n".join(cur));
            cur = [line];
        } else {
            cur.append(line);
        }
    }
    if cur {
        chunks.append("\n".join(cur));
    }
    return chunks;
}


def _parse_one_file(chunk: str) -> any {
    lines: list = chunk.split("\n");
    path: str = "";
    rows: list = [];
    hunks: list = [];
    cur_hunk: any = {};
    has_hunk: bool = False;
    hunk_index: int = -1;
    pending_old: str = "";
    has_pending: bool = False;
    row_index: int = 0;
    truncated: bool = False;
    for line_raw in lines {
        line: str = str(line_raw);
        if line.startswith("diff --git ") {
            parts: list = line.split(" ");
            if len(parts) >= 4 {
                path = str(parts[3]);
                if path.startswith("b/") {
                    path = path[2:];
                }
            }
            continue;
        }
        if line.startswith("+++ ") {
            p: str = line[4:].strip();
            if p.startswith("b/") {
                p = p[2:];
            }
            if p and p != "/dev/null" {
                path = p;
            }
            continue;
        }
        if line.startswith("@@ ") {
            if has_hunk {
                hunks.append(cur_hunk);
            }
            hunk_index += 1;
            has_hunk = True;
            cur_hunk = {
                "index": hunk_index,
                "header": line,
                "start_row": row_index,
                "end_row": row_index,
            };
            rows.append({
                "kind": "meta",
                "text": line,
                "hunk_index": hunk_index,
                "row_index": row_index,
            });
            row_index += 1;
            has_pending = False;
            continue;
        }
        if not path {
            continue;
        }
        if line.startswith("--- ") or line.startswith("index ") {
            continue;
        }
        if row_index >= max_rows_per_file() {
            truncated = True;
            break;
        }
        kind: str = "context";
        prefix: str = "";
        body: str = line;
        if line.startswith("+") {
            kind = "add";
            prefix = "+";
            body = line[1:];
        } elif line.startswith("-") {
            kind = "remove";
            prefix = "-";
            body = line[1:];
        } elif line.startswith(" ") {
            kind = "context";
            prefix = " ";
            body = line[1:];
        } else {
            continue;
        }
        inline: list = [];
        if kind == "remove" and not has_pending {
            pending_old = body;
            has_pending = True;
            continue;
        }
        if kind == "add" and has_pending {
            inline = inline_spans(pending_old, body);
            rows.append({
                "kind": "remove",
                "text": pending_old,
                "display": "-" + pending_old,
                "inline_spans": inline,
                "hunk_index": hunk_index,
                "row_index": row_index,
            });
            row_index += 1;
            if row_index < max_rows_per_file() {
                rows.append({
                    "kind": "add",
                    "text": body,
                    "display": "+" + body,
                    "inline_spans": inline,
                    "hunk_index": hunk_index,
                    "row_index": row_index,
                });
                row_index += 1;
            }
            has_pending = False;
            if has_hunk {
                cur_hunk["end_row"] = row_index - 1;
            }
            continue;
        }
        if has_pending {
            rows.append({
                "kind": "remove",
                "text": pending_old,
                "display": "-" + pending_old,
                "hunk_index": hunk_index,
                "row_index": row_index,
            });
            row_index += 1;
            has_pending = False;
        }
        display: str = prefix + body;
        if not prefix {
            display = body;
        }
        rows.append({
            "kind": kind,
            "text": body,
            "display": display,
            "hunk_index": hunk_index,
            "row_index": row_index,
        });
        row_index += 1;
        if has_hunk {
            cur_hunk["end_row"] = row_index - 1;
        }
    }
    if has_pending {
        rows.append({
            "kind": "remove",
            "text": pending_old,
            "display": "-" + pending_old,
            "hunk_index": hunk_index,
            "row_index": row_index,
        });
    }
    if has_hunk {
        hunks.append(cur_hunk);
    }
    if truncated {
        rows.append({
            "kind": "meta",
            "text": "… truncated (" + str(max_rows_per_file()) + " row cap)",
            "hunk_index": hunk_index,
            "row_index": row_index,
        });
    }
    if not path {
        return {};
    }
    return {"path": path, "rows": rows, "hunks": hunks};
}


def collect_git_patch(cwd: str, scope: str) -> any {
    if not cwd {
        cwd = os.getcwd();
    }
    scope = scope.strip().lower();
    cmd: list = ["git", "diff"];
    label: str = "working tree";
    if scope == "staged" or scope == "--staged" or scope == "cached" {
        cmd = ["git", "diff", "--staged"];
        label = "staged";
    } elif scope and scope not in ["", "work", "working"] {
        cmd = ["git", "diff", "--", scope];
        label = scope;
    }
    try {
        out: any = execSync(cmd, {
            "cwd": cwd,
            "encoding": "utf8",
            "maxBuffer": 10 * 1024 * 1024,
        });
        patch: str = "";
        if out {
            patch = str(out);
        }
        fc: int = 0;
        for line_raw in patch.split("\n") {
            line: str = str(line_raw);
            if line.startswith("diff --git ") {
                fc += 1;
            }
        }
        return {
            "ok": True,
            "patch": patch,
            "label": label,
            "error": "",
            "file_count": fc,
        };
    } except Exception as e {
        return {
            "ok": False,
            "patch": "",
            "label": label,
            "error": str(e),
            "file_count": 0,
        };
    }
}


def run_editor_on_text(content: str, cwd: str) -> str {
    editor: str = "vi";
    if "EDITOR" in os.environ {
        editor = str(os.environ["EDITOR"]);
    }
    parts: list = editor.split();
    if not parts {
        parts = ["vi"];
    }
    tmp: any = tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        suffix=".diffedit",
        delete=False,
    );
    path: str = str(tmp.name);
    tmp.write(content);
    tmp.close();
    try {
        spawnSync(str(parts[0]), parts + [path], {"cwd": cwd, "stdio": "inherit"});
        p: Path = Path(path);
        return p.read_text(encoding="utf-8");
    } finally {
        try {
            os.remove(path);
        } except Exception {
            _ignored: int = 0;
        }
    }
}


def read_file_text(cwd: str, rel_path: str) -> str {
    p: Path = Path(cwd) / rel_path;
    if not p.exists() {
        return "";
    }
    return p.read_text(encoding="utf-8");
}


def write_file_text(cwd: str, rel_path: str, content: str) {
    p: Path = Path(cwd) / rel_path;
    p.parent.mkdir(parents=True, exist_ok=True);
    p.write_text(content, encoding="utf-8");
}


def _parse_hunk_range(header: str, side: str) -> list {
    m: any = re.search(re.escape(side) + r"(\d+)(?:,(\d+))?", header);
    if not m {
        return [0, 0];
    }
    start: int = int(m.group(1));
    count: int = 1;
    if m.group(2) {
        count = int(m.group(2));
    }
    return [start, count];
}


def _hunk_new_lines(rows: list, start_row: int, end_row: int) -> list {
    out: list = [];
    for row_raw in rows {
        row: any = row_raw;
        ri: int = -1;
        if "row_index" in row {
            ri = int(row["row_index"]);
        }
        if ri < start_row or ri > end_row {
            continue;
        }
        k: str = "";
        if "kind" in row {
            k = str(row["kind"]);
        }
        if k == "meta" or k == "remove" {
            continue;
        }
        txt: str = "";
        if "text" in row {
            txt = str(row["text"]);
        }
        out.append(txt);
    }
    return out;
}


def _hunk_old_start(h: any) -> int {
    return int(h["old_start"]);
}


def apply_file_from_rows(
    cwd: str,
    file_path: str,
    rows: list,
    hunks: list,
    decisions: any,
) -> bool {
    original: str = read_file_text(cwd, file_path);
    orig_lines: list = original.split("\n");
    had_trailing: bool = len(original) > 0 and original.endswith("\n");
    if orig_lines and orig_lines[-1] == "" and had_trailing {
        orig_lines = orig_lines[0:-1];
    }
    ordered: list = [];
    for h_raw in hunks {
        h: any = h_raw;
        header: str = "";
        if "header" in h {
            header = str(h["header"]);
        }
        (old_start, old_count) = _parse_hunk_range(header, "-");
        hi: int = 0;
        if "index" in h {
            hi = int(h["index"]);
        }
        sr: int = 0;
        if "start_row" in h {
            sr = int(h["start_row"]);
        }
        er: int = 0;
        if "end_row" in h {
            er = int(h["end_row"]);
        }
        ordered.append({
            "index": hi,
            "header": header,
            "start_row": sr,
            "end_row": er,
            "old_start": old_start,
            "old_count": old_count,
        });
    }
    ordered.sort(key=_hunk_old_start);
    result: list = [];
    cursor: int = 0;
    for h_raw in ordered {
        h: any = h_raw;
        old_start: int = int(h["old_start"]);
        old_count: int = int(h["old_count"]);
        if old_start < 1 {
            continue;
        }
        idx0: int = old_start - 1;
        key: str = hunk_key(file_path, int(h["index"]));
        dec: str = "pending";
        if key in decisions {
            dec = str(decisions[key]);
        }
        while cursor < idx0 and cursor < len(orig_lines) {
            result.append(orig_lines[cursor]);
            cursor += 1;
        }
        if dec == "accepted" {
            new_seg: list = _hunk_new_lines(rows, int(h["start_row"]), int(h["end_row"]));
            for ln in new_seg {
                result.append(ln);
            }
            cursor = idx0 + old_count;
        } else {
            for _i in range(old_count) {
                if cursor < len(orig_lines) {
                    result.append(orig_lines[cursor]);
                    cursor += 1;
                }
            }
        }
    }
    while cursor < len(orig_lines) {
        result.append(orig_lines[cursor]);
        cursor += 1;
    }
    new_text: str = "\n".join(result);
    if had_trailing {
        new_text += "\n";
    }
    write_file_text(cwd, file_path, new_text);
    return True;
}


def write_accepted_files(
    cwd: str,
    files: any,
    rows_by_file: any,
    hunks_by_file: any,
    decisions: any,
) -> list {
    written: list = [];
    for fp_raw in files {
        fp: str = str(fp_raw);
        hunks: list = [];
        if fp in hunks_by_file {
            hunks = hunks_by_file[fp];
        }
        has_accept: bool = False;
        for h_raw in hunks {
            h: any = h_raw;
            hi: int = int(h["index"]);
            key: str = hunk_key(fp, hi);
            dec: str = "";
            if key in decisions {
                dec = str(decisions[key]);
            }
            if dec == "accepted" {
                has_accept = True;
                break;
            }
        }
        if not has_accept {
            continue;
        }
        file_rows: list = [];
        if fp in rows_by_file {
            file_rows = rows_by_file[fp];
        }
        apply_file_from_rows(cwd, fp, file_rows, hunks, decisions);
        written.append(fp);
    }
    return written;
}


def:pub new_diff_state() -> any {
    return {
        "active": False,
        "files": [],
        "rows_by_file": {},
        "hunks_by_file": {},
        "selected_file": 0,
        "selected_hunk": 0,
        "selected_line": 0,
        "scroll_top": 0,
        "mode": "navigate",
        "decisions": {},
        "cwd": "",
        "label": "",
        "error": "",
        "dirty": False,
        "confirm_quit": False,
        "status_message": "",
    };
}


def:pub diff_snapshot(st: any) -> any {
    return {
        "active": st["active"],
        "files": list(st["files"]),
        "rows_by_file": st["rows_by_file"],
        "hunks_by_file": st["hunks_by_file"],
        "selected_file": st["selected_file"],
        "selected_hunk": st["selected_hunk"],
        "selected_line": st["selected_line"],
        "scroll_top": st["scroll_top"],
        "mode": st["mode"],
        "decisions": {**st["decisions"]},
        "cwd": st["cwd"],
        "label": st["label"],
        "error": st["error"],
        "dirty": st["dirty"],
        "confirm_quit": st["confirm_quit"],
        "status_message": st["status_message"],
    };
}


def _current_file(st: any) -> str {
    files: list = list(st["files"]);
    i: int = int(st["selected_file"]);
    if not files or i < 0 or i >= len(files) {
        return "";
    }
    return str(files[i]);
}


def _current_rows(st: any) -> list {
    fp: str = _current_file(st);
    if not fp {
        return [];
    }
    rows_by: any = st["rows_by_file"];
    if fp in rows_by {
        return list(rows_by[fp]);
    }
    return [];
}


def _current_hunks(st: any) -> list {
    fp: str = _current_file(st);
    if not fp {
        return [];
    }
    hunks_by: any = st["hunks_by_file"];
    if fp in hunks_by {
        return list(hunks_by[fp]);
    }
    return [];
}


def:pub diff_open(st: any, cwd: str, scope: str) -> any {
    if not cwd {
        cwd = os.getcwd();
    }
    git_r: any = collect_git_patch(cwd, scope);
    st["cwd"] = cwd;
    st["label"] = git_r["label"];
    if not git_r["ok"] {
        st["error"] = git_r["error"];
    } else {
        st["error"] = "";
    }
    st["active"] = True;
    st["selected_file"] = 0;
    st["selected_hunk"] = 0;
    st["selected_line"] = 0;
    st["scroll_top"] = 0;
    st["mode"] = "navigate";
    st["decisions"] = {};
    st["dirty"] = False;
    st["confirm_quit"] = False;
    st["status_message"] = "";
    if not git_r["ok"] {
        st["files"] = [];
        st["rows_by_file"] = {};
        st["hunks_by_file"] = {};
        return diff_snapshot(st);
    }
    parsed: any = parse_multi_file_patch(str(git_r["patch"]));
    st["files"] = parsed["files"];
    st["rows_by_file"] = parsed["rows_by_file"];
    st["hunks_by_file"] = parsed["hunks_by_file"];
    if not st["files"] {
        st["error"] = "No differences.";
    }
    return diff_snapshot(st);
}


def:pub diff_close(st: any, force: bool) -> bool {
    if st["dirty"] and not force and not st["confirm_quit"] {
        st["confirm_quit"] = True;
        st["status_message"] = "Unsaved hunk decisions — press q again to discard";
        return False;
    }
    st["active"] = False;
    st["confirm_quit"] = False;
    st["status_message"] = "";
    return True;
}


def _ensure_line_visible(st: any) {
    viewport: int = 12;
    top: int = int(st["scroll_top"]);
    li: int = int(st["selected_line"]);
    if li < top {
        st["scroll_top"] = li;
    } elif li >= top + viewport {
        st["scroll_top"] = li - viewport + 1;
    }
}


def _sync_hunk_from_line(st: any) {
    rows: list = _current_rows(st);
    li: int = int(st["selected_line"]);
    if not rows or li < 0 or li >= len(rows) {
        return;
    }
    row: any = rows[li];
    hi: int = -1;
    if "hunk_index" in row {
        hi = int(row["hunk_index"]);
    }
    if hi >= 0 {
        st["selected_hunk"] = hi;
    }
}


def:pub diff_move_line(st: any, delta: int) -> any {
    rows: list = _current_rows(st);
    if not rows {
        return diff_snapshot(st);
    }
    n: int = len(rows);
    next_line: int = int(st["selected_line"]) + delta;
    if next_line < 0 {
        next_line = 0;
    }
    if next_line > n - 1 {
        next_line = n - 1;
    }
    st["selected_line"] = next_line;
    _ensure_line_visible(st);
    _sync_hunk_from_line(st);
    return diff_snapshot(st);
}


def:pub diff_next_hunk(st: any, delta: int) -> any {
    hunks: list = _current_hunks(st);
    if not hunks {
        return diff_snapshot(st);
    }
    n: int = len(hunks);
    cur: int = int(st["selected_hunk"]);
    idx: int = 0;
    for i in range(len(hunks)) {
        h: any = hunks[i];
        if int(h["index"]) == cur {
            idx = i;
            break;
        }
    }
    next_i: int = idx + delta;
    if next_i < 0 {
        next_i = 0;
    }
    if next_i > n - 1 {
        next_i = n - 1;
    }
    next_hunk: any = hunks[next_i];
    st["selected_hunk"] = int(next_hunk["index"]);
    sr: int = 0;
    if "start_row" in next_hunk {
        sr = int(next_hunk["start_row"]);
    }
    st["selected_line"] = sr;
    _ensure_line_visible(st);
    return diff_snapshot(st);
}


def:pub diff_next_file(st: any, delta: int) -> any {
    files: list = list(st["files"]);
    if not files {
        return diff_snapshot(st);
    }
    n: int = len(files);
    cur: int = int(st["selected_file"]);
    st["selected_file"] = (cur + delta + n) % n;
    st["selected_hunk"] = 0;
    st["selected_line"] = 0;
    st["scroll_top"] = 0;
    return diff_snapshot(st);
}


def:pub diff_accept_hunk(st: any) -> any {
    fp: str = _current_file(st);
    if not fp {
        return diff_snapshot(st);
    }
    key: str = hunk_key(fp, int(st["selected_hunk"]));
    st["decisions"][key] = "accepted";
    st["dirty"] = True;
    st["status_message"] = "accepted " + key;
    return diff_snapshot(st);
}


def:pub diff_reject_hunk(st: any) -> any {
    fp: str = _current_file(st);
    if not fp {
        return diff_snapshot(st);
    }
    key: str = hunk_key(fp, int(st["selected_hunk"]));
    st["decisions"][key] = "rejected";
    st["dirty"] = True;
    st["status_message"] = "rejected " + key;
    return diff_snapshot(st);
}


def:pub diff_write_files(st: any) -> any {
    written: list = write_accepted_files(
        str(st["cwd"]),
        st["files"],
        st["rows_by_file"],
        st["hunks_by_file"],
        st["decisions"],
    );
    if written {
        st["status_message"] = "wrote: " + ", ".join(written);
        st["dirty"] = False;
        st["confirm_quit"] = False;
    } else {
        st["status_message"] = "no accepted hunks to write";
    }
    return diff_snapshot(st);
}


def:pub diff_edit_selection(st: any) -> any {
    rows: list = _current_rows(st);
    li: int = int(st["selected_line"]);
    if not rows or li < 0 or li >= len(rows) {
        return diff_snapshot(st);
    }
    row: any = rows[li];
    text: str = "";
    if "text" in row {
        text = str(row["text"]);
    }
    edited: str = run_editor_on_text(text, str(st["cwd"]));
    row["text"] = edited;
    rk: str = "";
    if "kind" in row {
        rk = str(row["kind"]);
    }
    if rk == "add" {
        row["display"] = "+" + edited;
    } elif rk == "remove" {
        row["display"] = "-" + edited;
    } else {
        row["display"] = " " + edited;
    }
    st["dirty"] = True;
    st["status_message"] = "edited line (re-run /diff to refresh git view)";
    return diff_snapshot(st);
}


def:pub diff_scroll_page(st: any, delta: int) -> any {
    next_top: int = int(st["scroll_top"]) + delta;
    if next_top < 0 {
        next_top = 0;
    }
    st["scroll_top"] = next_top;
    return diff_snapshot(st);
}
