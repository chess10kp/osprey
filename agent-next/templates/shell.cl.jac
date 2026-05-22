"""Jackal TUI Shell — minimal local chat (no Pi interop)."""

import from "ink" { Box, Text, useInput }


def:pub app() -> JsxElement {
    has phase: str = "ready";
    has input_text: str = "";
    has status_text: str = "ready";
    has lines: list[str] = [];

    def submit_input() -> None {
        cmd = input_text.strip();
        if not cmd {
            return;
        }
        input_text = "";

        if cmd == "/exit" or cmd == "/quit" {
            globalThis.process.exit(0);
            return;
        }

        if cmd == "/clear" {
            lines = [];
            status_text = "cleared";
            return;
        }

        phase = "streaming";
        status_text = "responding";

        next_lines = lines.copy();
        next_lines.append("> " + cmd);
        next_lines.append("jackal> " + cmd);
        lines = next_lines;

        phase = "ready";
        status_text = "ready";
    }

    useInput(
        lambda (ch: str, key: Any) -> None { if key.return {
            submit_input();
        } elif key.backspace or key.delete {
            input_text = input_text[:-1];
        } elif ch and not key.ctrl and not key.meta {
            input_text = input_text + ch;
        }  }
    );

    phase_color: str = "green" if phase == "streaming" else "cyan";

    out_text = "\n".join(lines[-40:]);

    return
        <Box flexDirection="column" padding={0}>
            <Box flexDirection="row" justifyContent="space-between" paddingX={1}>
                <Text bold color="magenta">{"Jackal"}</Text>
                <Text color={phase_color}>{phase}</Text>
                <Text dimColor>{"local"}</Text>
            </Box>
            <Text color="gray">{"─" * 60}</Text>
            <Box flexDirection="column" paddingX={1}>
                <Text>{out_text}</Text>
            </Box>
            <Box borderStyle="single" borderColor="gray" paddingX={1}>
                <Text dimColor>{status_text + "  |  /clear /exit"}</Text>
            </Box>
            <Box paddingX={1}>
                <Text color="green" bold>{"> "}</Text>
                <Text>{input_text}</Text>
                <Text dimColor>{"_"}</Text>
            </Box>
        </Box>;
}
