"""StreamingMessage — live streaming assistant text with spinner + model header + token counter.
Ported from nanocoder's StreamingMessage."""

import from "ink" { Box, Text }
import from "@inkjs/ui" { Spinner }
import from .theme { SECONDARY, INFO, TEXT, ACCENT }


def stream_truncate(text: str, max_lines: int) -> str {
    if not text { return ""; }
    lines: list = text.split("\n");
    if len(lines) <= max_lines { return text; }
    return "…" + "\n".join(lines[-max_lines:]);
}


def stream_estimate_tokens(text: str) -> int {
    if not text { return 0; }
    # Rough estimate: ~4 chars per token
    return int(len(text) / 4);
}


def:pub StreamingMessage(streaming_text: str, model: str) -> JsxElement {
    # Show tail of content to keep render small
    display: str = stream_truncate(streaming_text, 15);
    tokens: int = stream_estimate_tokens(streaming_text);

    return (
        <Box flexDirection="column">
            <Box marginBottom={1} marginTop={1}>
                <Text color={INFO} bold>
                    <Spinner type="dots" /> {" " + (model if model else "Thinking")}
                </Text>
                <Text>
                    {"  ~" + str(tokens) + " tokens"}
                </Text>
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
