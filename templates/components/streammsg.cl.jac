"""StreamingMessage — live streaming assistant text with spinner + model header + token counter.
Shows tail-truncated plain text during streaming for cheap re-renders.
Full markdown rendering happens in AssistantMessage when the turn completes."""

import from "ink" { Box, Text }
import from "@inkjs/ui" { Spinner }
import from .theme { SECONDARY, INFO, TEXT, ACCENT }


def stream_truncate(text: str, max_lines: int) -> str {
    if not text { return ""; }
    lines: list = text.split(chr(10));
    if len(lines) <= max_lines { return text; }
    tail: list = lines[-max_lines:];
    return "…" + chr(10).join(tail);
}


def stream_estimate_tokens(text: str) -> int {
    if not text { return 0; }
    # Rough estimate: ~4 chars per token
    return int(len(text) / 4);
}


def:pub StreamingMessage(props: any) -> JsxElement {
    streaming_text: str = str(props.streaming_text) if props.streaming_text else "";
    model: str = str(props.model) if props.model else "";
    display: str = stream_truncate(streaming_text, 15);
    tokens: int = stream_estimate_tokens(streaming_text);

    return (
        <Box flexDirection="column">
            <Box marginBottom={1} marginTop={1} flexDirection="row">
                <Spinner type="dots" />
                <Text color={INFO} bold>{" " + (model if model else "Thinking")}</Text>
                <Text>{"  ~" + str(tokens) + " tokens"}</Text>
            </Box>
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
        </Box>
    );
}
