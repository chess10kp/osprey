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
    if percent >= 85.0 { return "red"; }
    if percent >= 60.0 { return "yellow"; }
    return "green";
}


def context_text(percent: float) -> str {
    base: str = str(int(percent)) + "%";
    if percent >= 60.0 { return base + " · /compact"; }
    return base;
}


def context_progress_bar(percent: float, width: int) -> str {
    pct: float = percent;
    if pct < 0.0 { pct = 0.0; }
    if pct > 100.0 { pct = 100.0; }
    bar_w: int = width;
    if bar_w < 4 { bar_w = 4; }
    filled: int = int(round((bar_w * pct) / 100.0));
    if filled > bar_w { filled = bar_w; }
    empty: int = bar_w - filled;
    bar: str = "";
    for _ in range(filled) { bar = bar + "█"; }
    for _ in range(empty) { bar = bar + "░"; }
    return bar;
}


def:pub StatusBar(
    phase: str,
    model: str,
    provider: str,
    context_percent: float,
    mcp_connected: int,
    mcp_total: int,
) -> JsxElement {
    model_display: str = model if model else "(no model)";
    pc: str = phase_color(phase);
    pl: str = phase_label(phase);
    ctx_color: str = context_color(context_percent);
    ctx_text: str = context_text(context_percent);
    ctx_bar: str = context_progress_bar(context_percent, 10);

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
            </Box>
            <Box flexDirection="row">
                <Text color={ctx_color}>{ctx_bar}</Text>
                <Text>{" "}</Text>
                <Text color={ctx_color}>{ctx_text}</Text>
                {mcp_total > 0 and (
                    <Text color="gray">{"  MCP: " + str(mcp_connected) + "/" + str(mcp_total)}</Text>
                )}
            </Box>
        </Box>
    );
}
