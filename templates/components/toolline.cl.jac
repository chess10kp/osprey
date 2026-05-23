"""ToolTimeline — running/done tool execution list with icons. Ported from nanocoder's tool display."""

import from "ink" { Box, Text }
import from .theme { TOOL, SECONDARY, SUCCESS, WARNING }


def:pub ToolRow(
    tool_name: str,
    status: str,
    input_preview: str,
) -> JsxElement {
    running: bool = status == "running";
    has color: str = "green";
    if running { color = "yellow"; }
    has icon: str = "✓";
    if running { icon = "⏵"; }
    detail: str = input_preview if input_preview else "";

    # Truncate detail to 60 chars
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
    # Show last 8 tools
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
