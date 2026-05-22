"""Jackal TUI Shell — minimal send/receive chat UI."""

import from "ink" { Box, Text, useInput }


def:pub app() -> JsxElement {
    has phase: str = "booting";
    has model_label: str = "no model";
    has stream_text: str = "";
    has input_text: str = "";
    has status_text: str = "booting";
    has transcript_text: str = "";
    has clear_offset: int = 0;

    async can with entry {
        adapter = globalThis.__jackal;
        if not adapter {
            phase = "error";
            status_text = "No adapter found. Use jackal runner.";
            return;
        }

        store = adapter.store;

        store.subscribe(
            lambda() -> None {
                snap = store.getSnapshot();
                phase = snap.phase if snap.phase else "ready";
                p = snap.provider if snap.provider else "";
                m = snap.model if snap.model else "";
                model_label = f"{p}/{m}" if m else "no model";
                msgs = snap.messages if snap.messages else [];
                if clear_offset > len(msgs) {
                    clear_offset = len(msgs);
                }
                lines: list[str] = [];
                for msg in msgs[clear_offset:] {
                    prefix = "> " if msg.role == "user" else "";
                    lines.append(prefix + msg.text);
                }
                transcript_text = "\n".join(lines);
                stream_text = snap.streamingText if snap.streamingText else "";
                if snap.error {
                    status_text = "err: " + snap.error[:80];
                } else {
                    status_text = phase;
                }
            }
        );

        # Best-effort default model
        try {
            adapter.actions.setModel("github-copilot", "claude-haiku-4.5");
        } except Any {
            status_text = "No default model auth. Use configured provider.";
        }

        phase = "ready";
        status_text = "ready";
    }

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
            adapter = globalThis.__jackal;
            if adapter {
                snap = adapter.store.getSnapshot();
                msgs = snap.messages if snap.messages else [];
                clear_offset = len(msgs);
                transcript_text = "";
                stream_text = "";
                status_text = "cleared";
            }
            return;
        }

        adapter = globalThis.__jackal;
        if adapter {
            adapter.actions.send(cmd);
        }
    }

    useInput(
        lambda (ch: str, key: Any) -> None { if key.return {
            submit_input();
        } elif key.backspace or key.delete {
            input_text = input_text[:-1];
        } elif key.escape {
            adapter = globalThis.__jackal;
            if adapter {
                try {
                    adapter.actions.abort();
                } except Any {
                    None;
                }
            }
        } elif ch and not key.ctrl and not key.meta {
            input_text = input_text + ch;
        }   }
    );

    phase_color: str = "green"
        if phase == "streaming"
        else ("red" if phase == "error" else "cyan");

    return
        <Box flexDirection="column" padding={0}>
            <Box flexDirection="row" justifyContent="space-between" paddingX={1}>
                <Text bold color="magenta">{"Jackal"}</Text>
                <Text color={phase_color}>{phase}</Text>
                <Text dimColor>{model_label}</Text>
            </Box>
            <Text color="gray">{"─" * 60}</Text>
            <Box flexDirection="column" paddingX={1}>
                <Text>{transcript_text}</Text>
                <Text color="green">{stream_text}</Text>
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
