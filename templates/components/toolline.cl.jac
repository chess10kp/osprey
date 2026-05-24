"""Tool UI — transcript rows and timeline. Ported from nanocoder's tool display."""

import from "ink" { Box, Text }
import from .theme { TOOL, SECONDARY, SUCCESS, WARNING, ERROR }


def tool_format_input(input_obj: any) -> str {
    if input_obj is None { return ""; }
    preview: str = str(input_obj);
    if len(preview) > 80 { return preview[:80] + "…"; }
    return preview;
}


def tool_format_result(result: str, compact: bool) -> str {
    if not result { return ""; }
    if compact and len(result) > 80 { return result[:80] + "…"; }
    if (not compact) and len(result) > 2000 { return result[:2000] + "\n...[truncated]"; }
    if compact { return ""; }
    return result;
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
    result_text: str = tool_format_result(result_raw, compact);

    return (
        <Box flexDirection="column" paddingX={1} marginBottom={1}>
            <Box>
                <Text color={color}>{icon + " "}</Text>
                <Text bold color={TOOL}>{tool_name}</Text>
                {duration_label and <Text dimColor>{duration_label}</Text>}
            </Box>
            {input_preview and <Text dimColor>{"  args: " + input_preview}</Text>}
            {result_text and <Text dimColor>{"  " + result_text}</Text>}
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
