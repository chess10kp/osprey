"""Jackal TUI Shell — Ink-based coding agent.

Compiles via jac-tui to an Ink terminal app.
The custom runner.mjs injects the compiled TypeScript adapter
as globalThis.__jackal before mounting.
"""

import from "ink" { Box, Text, useInput }


# Global adapter reference — set by runner.mjs before mount
glob jackal: Any = None;


def:pub app() -> JsxElement {
    has phase: str = "booting";
    has model_label: str = "no model";
    has stream_text: str = "";
    has input_text: str = "";
    has error: str = "";
    has msg_lines: list[str] = [];
    has tool_count: int = 0;
    has running_count: int = 0;

    async can with entry {
        adapter = globalThis.__jackal;
        if not adapter {
            phase = "error";
            error = "No adapter found. Use jackal runner.";
            return;
        }

        store = adapter.store;

        # Subscribe to store changes
        store.subscribe(
            lambda() -> None {
                snap = store.getSnapshot();
                phase = snap.phase if snap.phase else "ready";
                p = snap.provider if snap.provider else "";
                m = snap.model if snap.model else "";
                model_label = f"{p}/{m}" if m else "no model";
                stream_text = snap.streamingText if snap.streamingText else "";
                error = snap.error if snap.error else "";
            }
        );

        # Auto-select first configured model
        auth_actions = adapter.authActions;
        providers = auth_actions.listProviders();
        if len(providers) > 0 {
            first = providers[0];
            models = auth_actions.listModels(first.id);
            if len(models) > 0 {
                fm = models[0];
                adapter.actions.setModel(first.id, fm.modelId);
            }
        }

        phase = "ready";
    }

    def do_submit() -> None {
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
            msg_lines = [];
            return;
        }

        adapter = globalThis.__jackal;
        if not adapter {
            return;
        }

        new_lines: list[str] = msg_lines.copy();
        new_lines.append("> " + cmd);
        new_lines.append("");
        msg_lines = new_lines;
        adapter.actions.send(cmd);
    }

    useInput(
        lambda (ch: str, key: Any) -> None { if key.return {
            do_submit();
        } elif key.backspace or key.delete {
            input_text = input_text[:-1];
        } elif key.escape {
            adapter = globalThis.__jackal;
            if adapter {
                try {
                    adapter.actions.abort();
                } except Any {
                    pass;
                }
            }
        } elif ch and not key.ctrl and not key.meta {
            input_text = input_text + ch;
        }   }
    );

    # ──── Render ───────────────────────────────────────────────────
    phase_color: str = "green"
        if phase == "streaming"
        else ("red" if phase == "error" else "cyan");

    # Build message output — return a list of JsxElements
    # We render the last 20 lines as individual <Text> elements
    visible = msg_lines[-20:];

    # Streaming line
    stream_el: Any = <Text/>;
    if stream_text {
        stream_el = <Text color="green">{stream_text}</Text>;
    }

    # Status
    status: str = phase;
    if error {
        status = "err: " + error[:60];
    }

    return
        <Box flexDirection="column" padding={0}>
            <Box flexDirection="row" justifyContent="space-between" paddingX={1}>
                <Text bold color="magenta">{"Jackal"}</Text>
                <Text color={phase_color}>{phase}</Text>
                <Text dimColor>{model_label}</Text>
            </Box>
            <Text color="gray">{"─" * 60}</Text>
            <Box flexDirection="column">
                {visible[0] if len(visible) > 0 else <Text/>}{visible[1]
                    if len(visible) > 1
                    else <Text/>}{visible[2] if len(visible) > 2 else <Text/>}{visible[
                    3
                ]
                    if len(visible) > 3
                    else <Text/>}{visible[4] if len(visible) > 4 else <Text/>}{visible[
                    5
                ]
                    if len(visible) > 5
                    else <Text/>}{visible[6] if len(visible) > 6 else <Text/>}{visible[
                    7
                ]
                    if len(visible) > 7
                    else <Text/>}{visible[8] if len(visible) > 8 else <Text/>}{visible[
                    9
                ]
                    if len(visible) > 9
                    else <Text/>}{visible[10] if len(visible) > 10 else <Text/>}{visible[
                    11
                ]
                    if len(visible) > 11
                    else <Text/>}{visible[12] if len(visible) > 12 else <Text/>}{visible[
                    13
                ]
                    if len(visible) > 13
                    else <Text/>}{visible[14] if len(visible) > 14 else <Text/>}{visible[
                    15
                ]
                    if len(visible) > 15
                    else <Text/>}{visible[16] if len(visible) > 16 else <Text/>}{visible[
                    17
                ]
                    if len(visible) > 17
                    else <Text/>}{visible[18] if len(visible) > 18 else <Text/>}{visible[
                    19
                ]
                    if len(visible) > 19
                    else <Text/>}{stream_el}
            </Box>
            <Box borderStyle="single" borderColor="gray" paddingX={1}>
                <Text dimColor>{status + "  |  Esc=abort"}</Text>
            </Box>
            <Box>
                <Text color="green" bold>{"> "}</Text>
                <Text>{input_text}</Text>
                <Text dimColor>{"_"}</Text>
            </Box>
        </Box>;
}
