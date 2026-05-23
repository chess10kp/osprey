"""AssistantMessage — finalized assistant response with model header + bordered box + token count.
Ported from nanocoder's AssistantMessage."""

import from "ink" { Box, Text }
import from .theme { SECONDARY, INFO, TEXT }


def asst_estimate_tokens(text: str) -> int {
    if not text { return 0; }
    return int(len(text) / 4);
}


def:pub AssistantMessage(message: str, model: str) -> JsxElement {
    tokens: int = asst_estimate_tokens(message);
    display: str = message.strip() if message else "";

    return (
        <Box flexDirection="column">
            <Box marginBottom={1} marginTop={1}>
                <Text color={INFO} bold>{(model if model else "Assistant") + ":"}</Text>
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
            <Box marginBottom={1}>
                <Text color={SECONDARY}>{"~" + str(tokens) + " tokens"}</Text>
            </Box>
        </Box>
    );
}
