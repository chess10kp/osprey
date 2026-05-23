"""UserMessage — bordered box showing the user's prompt. Ported from nanocoder."""

import from "ink" { Box, Text }
import from .theme { PRIMARY, SECONDARY, TEXT }


def:pub UserMessage(message: str, tokens: int) -> JsxElement {
    # Simple token estimate
    token_str: str = "~" + str(tokens) if tokens > 0 else "";

    return (
        <Box flexDirection="column">
            <Box marginBottom={1}>
                <Text color={PRIMARY} bold>{"You:"}</Text>
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
                borderLeftColor={PRIMARY}
            >
                <Text>{message}</Text>
            </Box>
            {token_str and (
                <Box marginBottom={1}>
                    <Text color={SECONDARY}>{token_str + " tokens"}</Text>
                </Box>
            )}
        </Box>
    );
}
