"""HelpPanel — command reference panel. Ported from nanocoder's help display."""

import from "ink" { Box, Text }
import from .theme { PRIMARY, SECONDARY, INFO, TEXT }


def:pub HelpPanel() -> JsxElement {
    return (
        <Box
            flexDirection="column"
            borderStyle="round"
            borderColor={INFO}
            paddingX={2}
            paddingY={1}
            marginTop={1}
        >
            <Text bold color={INFO}>{"Commands"}</Text>
            <Box flexDirection="column" marginTop={1}>
                <Text color={TEXT}>{"/help          toggle this panel"}</Text>
                <Text color={TEXT}>{"/login [p]     start auth flow"}</Text>
                <Text color={TEXT}>{"/logout <p>    logout provider"}</Text>
                <Text color={TEXT}>{"/model [p/m]   open picker or set"}</Text>
                <Text color={TEXT}>{"/cancel        cancel auth flow"}</Text>
                <Text color={TEXT}>{"/abort         cancel active run"}</Text>
                <Text color={TEXT}>{"/clear,/new    new session"}</Text>
                <Text color={TEXT}>{"/multiline     toggle multiline mode"}</Text>
                <Text color={TEXT}>{"/compact       compact context"}</Text>
                <Text color={TEXT}>{"/exit          quit"}</Text>
            </Box>
            <Text dimColor>
                {"↑/↓ = history   Tab = autocomplete   Esc = cancel   Ctrl+C = exit"}
            </Text>
        </Box>
    );
}
