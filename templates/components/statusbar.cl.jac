"""StatusBar -- provider/model/phase/context display. Ported from nanocoder's Status."""

import from "ink" { Box, Text }


def phase_color(phase: str) -> str {
    if phase == "streaming" { return "cyan"; }
    if phase == "compacting" { return "yellow"; }
    if phase == "retrying" { return "yellow"; }
    if phase == "error" { return "red"; }
    if phase == "ready" { return "green"; }
    return "gray";
}


def phase_label(phase: str) -> str {
    if phase == "booting" { return "Booting..."; }
    if phase == "ready" { return "Ready"; }
    if phase == "streaming" { return "Thinking"; }
    if phase == "compacting" { return "Compacting"; }
    if phase == "retrying" { return "Retrying"; }
    if phase == "error" { return "Error"; }
    return phase;
}


def context_color(percent: float) -> str {
    if percent >= 60.0 { return "yellow"; }
    return "green";
}


def context_text(percent: float) -> str {
    base: str = "Context: " + str(int(percent)) + "%";
    if percent >= 60.0 { return base + " (use /compact)"; }
    return base;
}


def:pub StatusBar(
    phase: str,
    model: str,
    provider: str,
    session_name: str,
    context_percent: float,
    mcp_connected: int,
    mcp_total: int,
) -> JsxElement {
    model_display: str = model if model else "(no model)";
    session_display: str = session_name if session_name else "new session";
    pc: str = phase_color(phase);
    pl: str = phase_label(phase);
    ctx_color: str = context_color(context_percent);
    ctx_text: str = context_text(context_percent);

    return (
        <Box
            flexDirection="column"
            borderStyle="round"
            borderColor="cyan"
            paddingX={2}
            paddingY={0}
        >
            <Box flexDirection="row" justifyContent="space-between">
                <Box flexDirection="row">
                    <Text color="magenta" bold>{"Jackal"}</Text>
                    <Text>{" "}</Text>
                    <Text color={pc}>{"● " + pl}</Text>
                </Box>
                <Box flexDirection="row">
                    <Text color="green" bold>{provider}</Text>
                    <Text color="gray">{"/"}</Text>
                    <Text color="green">{model_display}</Text>
                </Box>
                <Text color="gray">{session_display}</Text>
            </Box>
            <Box flexDirection="row">
                <Text color={ctx_color}>{ctx_text}</Text>
                {mcp_total > 0 and (
                    <Text color="gray">{"  MCP: " + str(mcp_connected) + "/" + str(mcp_total)}</Text>
                )}
            </Box>
        </Box>
    );
}
