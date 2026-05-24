"""Tool UI — transcript rows and timeline. Ported from nanocoder's tool display."""

import from "ink" { Box, Text }
import from .theme { PRIMARY, INFO, TEXT, SECONDARY, TOOL }
import from "../markdown.mjs" { parseMarkdownParts }


def tool_input_field(input_obj: any, key: str) -> str {
    if input_obj is None { return ""; }
    if hasattr(input_obj, key) {
        val: any = getattr(input_obj, key, None);
        if val is not None { return str(val); }
    }
    if hasattr(input_obj, "keys") and key in input_obj {
        val2: any = input_obj[key];
        if val2 is not None { return str(val2); }
    }
    if hasattr(input_obj, "get") {
        val3: any = input_obj.get(key, None);
        if val3 is not None { return str(val3); }
    }
    return "";
}


def tool_bash_command(input_obj: any) -> str {
    cmd: str = tool_input_field(input_obj, "command");
    if not cmd { cmd = tool_input_field(input_obj, "cmd"); }
    return cmd;
}


def tool_file_path(input_obj: any) -> str {
    path: str = tool_input_field(input_obj, "path");
    if not path { path = tool_input_field(input_obj, "file_path"); }
    if not path { path = tool_input_field(input_obj, "target_file"); }
    return path;
}


def tool_format_input(tool_name: str, input_obj: any) -> str {
    if input_obj is None { return ""; }

    if tool_name == "bash" {
        cmd: str = tool_bash_command(input_obj);
        if cmd { return "$ " + cmd; }
    }
    if tool_name == "read" or tool_name == "write" or tool_name == "edit" {
        path: str = tool_file_path(input_obj);
        if path {
            if tool_name == "read" { return "@ " + path; }
            if tool_name == "write" { return "→ " + path; }
            return path;
        }
    }
    if tool_name == "glob" {
        pattern: str = tool_input_field(input_obj, "pattern");
        if pattern { return pattern; }
    }

    preview: str = str(input_obj);
    if len(preview) > 80 { return preview[:80] + "…"; }
    return preview;
}


def tool_compact_description(tool_name: str, input_obj: any) -> str {
    if tool_name == "read" {
        path: str = tool_file_path(input_obj);
        if path {
            if len(path) > 60 { return "Read @ " + path[:57] + "…"; }
            return "Read @ " + path;
        }
        return "Read file";
    }
    if tool_name == "write" {
        path: str = tool_file_path(input_obj);
        if path {
            if len(path) > 60 { return "Wrote → " + path[:57] + "…"; }
            return "Wrote → " + path;
        }
        return "Wrote file";
    }
    if tool_name == "edit" {
        path: str = tool_file_path(input_obj);
        if path { return "Edited " + path; }
        return "Edited file";
    }
    if tool_name == "bash" {
        cmd: str = tool_bash_command(input_obj);
        if cmd {
            if len(cmd) > 60 { return "$ " + cmd[:57] + "…"; }
            return "$ " + cmd;
        }
        return "Ran shell command";
    }
    if tool_name == "glob" { return "File search"; }
    if tool_name == "agent" { return "Delegated 1 task to subagent"; }
    if tool_name == "mermaid" { return "Rendered 1 diagram"; }
    if tool_name == "jac_check" or tool_name == "jac_check_syntax" { return "Ran jac check"; }
    if tool_name == "jac_run" { return "Ran jac file"; }
    if tool_name == "jac_format" { return "Formatted jac file(s)"; }
    if tool_name == "jac_test" { return "Ran jac test"; }
    if tool_name == "jac_fix" { return "Ran jac fix loop"; }
    if tool_name == "jac_doctor" { return "Ran jac doctor"; }
    if tool_name == "jac_create" { return "Ran jac create"; }
    if tool_name == "jac_cli" { return "Ran jac CLI"; }
    if tool_name == "diagnostics" { return "Got diagnostics"; }
    if tool_name == "hover" { return "Looked up type info"; }
    if tool_name == "definition" { return "Found definition"; }
    if tool_name == "references" { return "Found references"; }
    if tool_name.startswith("jac_") { return "Ran " + tool_name; }
    return "Ran " + tool_name;
}


def tool_format_result(result: str, compact: bool) -> str {
    if not result or compact { return ""; }
    return result;
}


def tool_render_content_blocks(display: str) -> list {
    colors: dict = {
        "primary": PRIMARY,
        "secondary": SECONDARY,
        "info": INFO,
        "text": TEXT,
        "tool": TOOL,
    };
    parts: list = parseMarkdownParts(display, colors, 80);

    has_parts: bool = len(parts) > 0;
    single_empty: bool = len(parts) == 1 and not str(parts[0]["content"]).strip();

    if not has_parts or single_empty {
        return [
            <Box
                flexDirection="column"
                marginBottom={1}
                backgroundColor="#1a1a2e"
                padding={1}
                borderStyle="bold"
                borderLeft={true}
                borderRight={false}
                borderTop={false}
                borderBottom={false}
                borderLeftColor={SECONDARY}
            >
                <Text>{display}</Text>
            </Box>
        ];
    }

    rendered_parts: list = [];
    for i in range(len(parts)) {
        part: any = parts[i];
        ptype: str = str(part["type"]) if "type" in part else "text";
        pcontent: str = str(part["content"]) if "content" in part else "";
        if not pcontent.strip() { continue; }

        if ptype == "code" {
            rendered_parts.append(
                <Box key={i} flexDirection="column" marginBottom={1}>
                    <Text>{pcontent}</Text>
                </Box>
            );
        } else {
            rendered_parts.append(
                <Box
                    key={i}
                    flexDirection="column"
                    marginBottom={1}
                    backgroundColor="#1a1a2e"
                    padding={1}
                    borderStyle="bold"
                    borderLeft={true}
                    borderRight={false}
                    borderTop={false}
                    borderBottom={false}
                    borderLeftColor={SECONDARY}
                >
                    <Text>{pcontent}</Text>
                </Box>
            );
        }
    }
    return rendered_parts;
}


def:pub ToolMessage(props: any) -> JsxElement {
    tool_name: str = str(props.tool_name) if props.tool_name else "unknown";
    status: str = str(props.status) if props.status else "done";
    compact: bool = bool(props.compact) if props.compact is not None else False;
    running: bool = status == "running";
    is_error: bool = status == "error";
    color: str = "yellow" if running else ("red" if is_error else "green");
    icon: str = "⏵" if running else ("✗" if is_error else "✓");
    duration_ms: any = props.duration_ms;
    duration_label: str = "";
    if duration_ms is not None {
        duration_label = "  (" + str(duration_ms) + "ms)";
    }
    input_preview: str = tool_format_input(tool_name, props.input);
    result_raw: str = str(props.result) if props.result else "";
    show_compact: bool = compact and not is_error and not running;
    result_text: str = tool_format_result(result_raw, show_compact);
    result_blocks: list = tool_render_content_blocks(result_text) if result_text else [];

    if show_compact {
        summary: str = "";
        if props.summary {
            summary = str(props.summary);
        }
        if not summary {
            summary = tool_compact_description(tool_name, props.input);
        }
        return (
            <Box marginBottom={1} marginTop={1}>
                <Text color={color}>{icon + " "}</Text>
                <Text color={TOOL}>{summary}</Text>
                {duration_label and <Text dimColor>{duration_label}</Text>}
            </Box>
        );
    }

    return (
        <Box flexDirection="column">
            <Box marginBottom={1} marginTop={1}>
                <Text color={color}>{icon + " "}</Text>
                <Text color={INFO} bold>{tool_name + ":"}</Text>
                {duration_label and <Text dimColor>{duration_label}</Text>}
            </Box>
            {input_preview and (
                <Box
                    flexDirection="column"
                    marginBottom={1}
                    backgroundColor="#1a1a2e"
                    padding={1}
                    borderStyle="bold"
                    borderLeft={true}
                    borderRight={false}
                    borderTop={false}
                    borderBottom={false}
                    borderLeftColor={PRIMARY}
                >
                    <Text>{input_preview}</Text>
                </Box>
            )}
            {result_blocks}
        </Box>
    );
}


def:pub ToolRow(props: any) -> JsxElement {
    tool_name: str = str(props.tool_name) if props.tool_name else "unknown";
    status: str = str(props.status) if props.status else "done";
    input_preview: str = str(props.input_preview) if props.input_preview else "";
    running: bool = status == "running";
    color: str = "yellow" if running else "green";
    icon: str = "⏵" if running else "✓";
    detail: str = input_preview if input_preview else "";

    if len(detail) > 60 {
        detail = detail[:60] + "…";
    }

    return (
        <Box>
            <Text color={color}>{icon + " "}</Text>
            <Text bold>{tool_name}</Text>
            {detail and <Text dimColor>{"  " + detail}</Text>}
        </Box>
    );
}


def:pub ToolTimeline(
    tool_name_list: list,
    tool_status_list: list,
    tool_input_list: list,
) -> JsxElement {
    count: int = len(tool_name_list);
    start: int = 0;
    if count > 8 {
        start = count - 8;
    }

    rows: list = [];
    for i in range(start, count) {
        name: str = "unknown";
        if i < len(tool_name_list) {
            name = tool_name_list[i];
        }
        status: str = "done";
        if i < len(tool_status_list) {
            status = tool_status_list[i];
        }
        input_str: str = "";
        if i < len(tool_input_list) {
            input_str = tool_input_list[i];
        }
        rows.append(
            <ToolRow tool_name={name} status={status} input_preview={input_str}/>
        );
    }

    return (
        <Box flexDirection="column" paddingX={1} marginTop={1}>
            <Text dimColor bold>{"Tools"}</Text>
            {rows}
        </Box>
    );
}
