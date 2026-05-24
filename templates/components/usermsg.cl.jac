"""UserMessage — bordered box showing the user's prompt. Ported from nanocoder."""

import from "ink" { Box, Text }
import from .theme { PRIMARY }


def:pub UserMessage(props: any) -> JsxElement {
    message: str = str(props.message) if props.message else "";

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
        </Box>
    );
}
