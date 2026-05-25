"""File diff editor UI — renders diff overlay from engine snapshot."""

import from "ink" { Box, Text }
import from "./diff_engine.cl.jac" { get_terminal_width, truncate_to_width }


def diff_row_color(kind: str) -> str {
    if kind == "add" {
        return "green";
    }
    if kind == "remove" {
        return "red";
    }
    if kind == "meta" {
        return "cyan";
    }
    return "white";
}


def diff_span_color(kind: str) -> str {
    if kind == "add" {
        return "green";
    }
    if kind == "remove" {
        return "red";
    }
    return "white";
}


def render_diff_row(row: dict, selected: bool, width: int) -> any {
    kind: str = "context";
    if "kind" in row {
        kind = str(row["kind"]);
    }
    display: str = "";
    if "display" in row {
        display = str(row["display"]);
    } elif "text" in row {
        display = str(row["text"]);
    }
    spans: list = [];
    if "inline_spans" in row and row["inline_spans"] {
        spans = row["inline_spans"];
    }
    prefix: str = "> " if selected else "  ";
    line_text: str = truncate_to_width(prefix + display, width);
    if spans and len(spans) > 0 and kind in ["add", "remove"] {
        parts: list = [<Text>{prefix}</Text>];
        for s in spans {
            sk: str = "same";
            if "kind" in s {
                sk = str(s["kind"]);
            }
            st: str = "";
            if "text" in s {
                st = str(s["text"]);
            }
            parts.append(
                <Text color={diff_span_color(sk)} bold={selected and sk != "same"}>
                    {st}
                </Text>
            );
        }
        return (
            <Box>
                {parts}
            </Box>
        );
    }
    return (
        <Text color={diff_row_color(kind)} bold={selected}>
            {line_text}
        </Text>
    );
}


def:pub FileDiffEditor(props: any) -> JsxElement {
    state: any = props.state;
    active: bool = False;
    if "active" in state {
        active = bool(state["active"]);
    }
    if not active {
        return <Text></Text>;
    }
    files: list = [];
    if "files" in state {
        files = list(state["files"]);
    }
    rows_by: dict = {};
    if "rows_by_file" in state {
        rows_by = state["rows_by_file"];
    }
    hunks_by: dict = {};
    if "hunks_by_file" in state {
        hunks_by = state["hunks_by_file"];
    }
    sel_f: int = 0;
    if "selected_file" in state {
        sel_f = int(state["selected_file"]);
    }
    sel_line: int = 0;
    if "selected_line" in state {
        sel_line = int(state["selected_line"]);
    }
    scroll_top: int = 0;
    if "scroll_top" in state {
        scroll_top = int(state["scroll_top"]);
    }
    label: str = "diff";
    if "label" in state {
        label = str(state["label"]);
    }
    err: str = "";
    if "error" in state {
        err = str(state["error"]);
    }
    status: str = "";
    if "status_message" in state {
        status = str(state["status_message"]);
    }
    dirty: bool = False;
    if "dirty" in state {
        dirty = bool(state["dirty"]);
    }
    confirm: bool = False;
    if "confirm_quit" in state {
        confirm = bool(state["confirm_quit"]);
    }
    cwd: str = "";
    if "cwd" in state {
        cwd = str(state["cwd"]);
    }
    width: int = get_terminal_width();
    viewport_h: int = 14;
    fp: str = "";
    if files and sel_f >= 0 and sel_f < len(files) {
        fp = str(files[sel_f]);
    }
    rows: list = [];
    if fp and fp in rows_by {
        rows = list(rows_by[fp]);
    }
    hunks: list = [];
    if fp and fp in hunks_by {
        hunks = list(hunks_by[fp]);
    }
    visible: list = rows[scroll_top : scroll_top + viewport_h];
    row_nodes: list = [];
    for i in range(len(visible)) {
        real_i: int = scroll_top + i;
        is_sel: bool = real_i == sel_line;
        row_nodes.append(render_diff_row(visible[i], is_sel, width));
    }
    file_label: str = fp;
    if not fp {
        file_label = "(no file)";
    }
    fi: int = 0;
    if files {
        fi = sel_f + 1;
    }
    fn: int = len(files);
    hi: int = 0;
    if "selected_hunk" in state {
        hi = int(state["selected_hunk"]);
    }
    hn: int = len(hunks);
    dirty_mark: str = "";
    if dirty {
        dirty_mark = " *";
    }
    confirm_line: any = <Text></Text>;
    if confirm {
        confirm_line = (
            <Text color="yellow">{"Press q again to quit without writing"}</Text>
        );
    }
    return (
        <Box flexDirection="column" borderStyle="round" borderColor="magenta" paddingX={1} paddingY={1} marginTop={1}>
            <Text bold color="magenta">{"Diff — " + label + dirty_mark}</Text>
            <Text dimColor>{file_label + "  (" + str(fi) + "/" + str(fn) + ")  hunk " + str(hi) + "/" + str(hn)}</Text>
            {cwd and <Text dimColor>{cwd}</Text>}
            {err and <Text color="red">{err}</Text>}
            {status and <Text color="yellow">{status}</Text>}
            {confirm_line}
            {len(rows) == 0 and (not err) and (
                <Text dimColor>{"No diff rows. Try /diff staged or edit files first."}</Text>
            )}
            {row_nodes}
            <Text dimColor>{"j/k line  n/p hunk  a accept  r reject  e edit  Tab file  Enter write  q quit"}</Text>
        </Box>
    );
}
