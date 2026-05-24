"""Tool UI — transcript rows and timeline. Ported from nanocoder's tool display."""

import from "ink" { Box, Text }
import from .theme { PRIMARY, INFO, TEXT, SECONDARY, TOOL }
import from "../markdown.mjs" { parseMarkdownParts }


def tool_format_input(input_obj: any) -> str {
    if input_obj is None { return ""; }
    preview: str = str(input_obj);
    if len(preview) > 80 { return preview[:80] + "…"; }
    return preview;
}


def tool_compact_description(tool_name: str) -> str {
    if tool_name == "read" { return "Read 1 file"; }
    if tool_name == "write" { return "Wrote 1 file"; }
    if tool_name == "edit" { return "Made 1 edit"; }
    if tool_name == "bash" { return "Ran 1 command"; }
    if tool_name == "glob" { return "Ran 1 file search"; }
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
    return "Executed " + tool_name;
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
    input_preview: str = tool_format_input(props.input);
    result_raw: str = str(props.result) if props.result else "";
    show_compact: bool = compact and not is_error and not running;
    result_text: str = tool_format_result(result_raw, show_compact);
    result_blocks: list = tool_render_content_blocks(result_text) if result_text else [];

    if show_compact {
        summary: str = tool_compact_description(tool_name);
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
