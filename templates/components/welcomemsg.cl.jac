"""WelcomeMessage — ASCII banner + tips box. Ported from nanocoder."""

import from "ink" { Box, Text }
import from .theme { PRIMARY, SECONDARY, TEXT, ACCENT }


def:pub WelcomeMessage(version: str) -> JsxElement {
    return (
        <Box flexDirection="column" marginBottom={1}>
            <Box flexDirection="column">
                <Text color={ACCENT} bold>{"     ██╗ █████╗  ██████╗██╗  ██╗ █████╗ ██╗     "}</Text>
                <Text color={ACCENT} bold>{"     ██║██╔══██╗██╔════╝██║ ██╔╝██╔══██╗██║     "}</Text>
                <Text color={ACCENT} bold>{"     ██║███████║██║     █████╔╝ ███████║██║     "}</Text>
                <Text color={ACCENT} bold>{"██   ██║██╔══██║██║     ██╔═██╗ ██╔══██║██║     "}</Text>
                <Text color={ACCENT} bold>{"╚█████╔╝██║  ██║╚██████╗██║  ██╗██║  ██║███████╗"}</Text>
                <Text color={ACCENT} bold>{" ╚════╝ ╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝"}</Text>
            </Box>
            <Box
                flexDirection="column"
                borderStyle="round"
                borderColor={PRIMARY}
                paddingX={2}
                paddingY={1}
                marginBottom={1}
            >
                <Box marginBottom={1}>
                    <Text color={PRIMARY} bold>{"✻ Welcome to Jackal" + (version if version else "") + " ✻"}</Text>
                </Box>
                <Box paddingBottom={1} flexDirection="column">
                    <Text color={SECONDARY}>{"1. Use natural language to describe your task."}</Text>
                    <Text color={SECONDARY}>{"2. Ask for file analysis, editing, bash commands and more."}</Text>
                    <Text color={SECONDARY}>{"3. Be specific for best results."}</Text>
                    <Text color={SECONDARY}>{"4. Type /help for commands, /exit or Ctrl+C to quit."}</Text>
                </Box>
                <Text color={TEXT}>{"/help for help"}</Text>
            </Box>
        </Box>
    );
}
