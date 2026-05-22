"""Jackal TUI Shell — Ink shell wired to the headless Pi adapter via @jac/pi."""

import from "ink" { Box, Text, useInput }
import from "@jac/pi" {
    usePiBoot,
    usePiSession,
    useAgentState,
    useAgentStream,
    useMessages,
    useToolTimeline,
    useAuthFlow,
    useExtensionUI,
    useCompletions
}


# ─── small helpers ───────────────────────────────────────────────────────────
def truncate(text: str, n: int) -> str {
    if not text {
        return "";
    }
    if len(text) <= n {
        return text;
    }
    return text[:n] + "…";
}


def to_str(value: any) -> str {
    if value is None {
        return "";
    }
    return str(value);
}


def exit_app(code: int) -> None {
    g: any = globalThis;
    g.process.exit(code);
}


def list_len(value: any) -> int {
    if not value {
        return 0;
    }
    return len(list(value));
}


# ─── overlays ────────────────────────────────────────────────────────────────
def:pub ProviderRow(props: any) -> JsxElement {
    p: any = props.provider;
    marker: str = "●" if p.configured else "○";
    color: str = "green" if p.configured else "yellow";
    info: str = "  " + to_str(p.displayName) + "  (" + to_str(p.authType) + ", " + str(
        p.modelCount
    ) + " models)";
    return (
        <Box>
            <Text color={color}>{marker + " "}</Text>
            <Text bold>{to_str(p.id)}</Text>
            <Text dimColor>{info}</Text>
        </Box>
    );
}


def:pub ProviderPicker(props: any) -> JsxElement {
    step: any = props.step;
    providers: list = list(step.providers);
    rows: list = [<ProviderRow provider={p}/> for p in providers];
    return (
        <Box flexDirection="column" borderStyle="round" borderColor="cyan" paddingX={1}>
            <Text bold color="cyan">{"Select a provider"}</Text>
            <Text dimColor>{"Type the id and press Enter. Esc to cancel."}</Text>
            {rows}
        </Box>
    );
}


def:pub BrowserAuthView(props: any) -> JsxElement {
    step: any = props.step;
    instr: any = step.instructions;
    return (
        <Box
            flexDirection="column"
            borderStyle="round"
            borderColor="magenta"
            paddingX={1}
        >
            <Text bold color="magenta">{"Browser authentication"}</Text>
            <Text>{"Open in browser:"}</Text>
            <Text color="cyan">{to_str(step.url)}</Text>
            {instr and <Text dimColor>{to_str(instr)}</Text>}
            <Text dimColor>{"Esc to cancel."}</Text>
        </Box>
    );
}


def:pub AuthPromptView(props: any) -> JsxElement {
    step: any = props.step;
    input_text: str = to_str(props.input_text);
    msg: str = to_str(step.message) if step.message else "Input required";
    return (
        <Box
            flexDirection="column"
            borderStyle="round"
            borderColor="yellow"
            paddingX={1}
        >
            <Text bold color="yellow">{msg}</Text>
            <Box>
                <Text color="green">{"> "}</Text>
                <Text>{input_text}</Text>
                <Text dimColor>{"_"}</Text>
            </Box>
            <Text dimColor>{"Enter to submit, Esc to cancel."}</Text>
        </Box>
    );
}


def:pub ModelRow(props: any) -> JsxElement {
    m: any = props.model;
    return
        <Text>{"  " + to_str(m.provider) + "/" + to_str(m.modelId)}</Text>;
}


def:pub ModelPicker(props: any) -> JsxElement {
    step: any = props.step;
    query: str = to_str(step.query).lower();
    models: list = list(step.models);
    filtered: list = [];
    for m in models {
        label: str = (to_str(m.provider) + "/" + to_str(m.modelId)).lower();
        if (not query) or (query in label) {
            filtered.append(m);
        }
    }
    shown: list = filtered[:15];
    rows: list = [<ModelRow model={m}/> for m in shown];
    extra: int = len(filtered) - 15;
    return (
        <Box flexDirection="column" borderStyle="round" borderColor="cyan" paddingX={1}>
            <Text bold color="cyan">{"Select a model"}</Text>
            <Text dimColor>{"Type 'provider/model' and Enter. Esc to cancel."}</Text>
            {rows}
            {(extra > 0) and <Text dimColor>{"  … " + str(extra) + " more"}</Text>}
        </Box>
    );
}


def:pub AuthErrorView(props: any) -> JsxElement {
    step: any = props.step;
    return (
        <Box flexDirection="column" borderStyle="round" borderColor="red" paddingX={1}>
            <Text bold color="red">{"Auth error"}</Text>
            <Text>{to_str(step.message)}</Text>
            <Text dimColor>{"Esc to dismiss. /login to retry."}</Text>
        </Box>
    );
}


def:pub DialogOption(props: any) -> JsxElement {
    idx: int = int(props.index);
    return
        <Text>{"  " + str(idx + 1) + ". " + to_str(props.option)}</Text>;
}


def:pub DialogOverlay(props: any) -> JsxElement {
    dialog: any = props.dialog;
    input_text: str = to_str(props.input_text);
    kind: str = to_str(dialog.kind);

    if kind == "select" {
        opts: list = list(dialog.options) if dialog.options else [];
        rows: list = [
            <DialogOption option={o} index={i}/> for (i, o) in enumerate(opts)
        ];
        return (
            <Box
                flexDirection="column"
                borderStyle="round"
                borderColor="blue"
                paddingX={1}
            >
                <Text bold color="blue">{to_str(dialog.title)}</Text>
                {rows}
                <Box>
                    <Text color="green">{"> "}</Text>
                    <Text>{input_text}</Text>
                </Box>
                <Text dimColor>
                    {"Type option text or number, Enter to submit, Esc to dismiss."}
                </Text>
            </Box>
        );
    }
    if kind == "confirm" {
        msg: any = dialog.message;
        return (
            <Box
                flexDirection="column"
                borderStyle="round"
                borderColor="blue"
                paddingX={1}
            >
                <Text bold color="blue">{to_str(dialog.title)}</Text>
                {msg and <Text>{to_str(msg)}</Text>}
                <Text dimColor>{"y = yes, n = no, Esc = dismiss"}</Text>
            </Box>
        );
    }
    placeholder: str = to_str(dialog.placeholder);
    display: str = input_text if input_text else placeholder;
    return (
        <Box flexDirection="column" borderStyle="round" borderColor="blue" paddingX={1}>
            <Text bold color="blue">{to_str(dialog.title)}</Text>
            <Box>
                <Text color="green">{"> "}</Text>
                <Text>{display}</Text>
            </Box>
            <Text dimColor>{"Enter to submit, Esc to dismiss."}</Text>
        </Box>
    );
}


def:pub CompletionsList(props: any) -> JsxElement {
    items: list = list(props.items)[:6];
    rows: list = [<Text dimColor>{"  " + to_str(s.label)} </Text> for s in items];
    return (
        <Box
            flexDirection="column"
            borderStyle="single"
            borderColor="gray"
            paddingX={1}
        >
            {rows}
        </Box>
    );
}


def:pub ToolRow(props: any) -> JsxElement {
    t: any = props.tool;
    running: bool = to_str(t.status) == "running";
    color: str = "yellow" if running else "green";
    icon: str = "⏵" if running else "✓";
    detail: str = truncate(to_str(t.input), 60);
    return (
        <Box>
            <Text color={color}>{icon + " "}</Text>
            <Text bold>{to_str(t.toolName)}</Text>
            <Text dimColor>{"  " + detail}</Text>
        </Box>
    );
}


def:pub MessageRow(props: any) -> JsxElement {
    m: any = props.message;
    role: str = to_str(m.role);
    text: str = to_str(m.text);
    if role == "user" {
        return (
            <Box>
                <Text color="green" bold>{"› "}</Text>
                <Text>{text}</Text>
            </Box>
        );
    }
    return (
        <Box>
            <Text color="magenta" bold>{"⎇ "}</Text>
            <Text>{text}</Text>
        </Box>
    );
}


def:pub HelpPanel() -> JsxElement {
    return (
        <Box
            flexDirection="column"
            borderStyle="single"
            borderColor="blue"
            paddingX={1}
        >
            <Text bold color="blue">{"Commands"}</Text>
            <Text>{"/help          toggle this panel"}</Text>
            <Text>{"/login [p]     start auth flow"}</Text>
            <Text>{"/logout <p>    logout provider"}</Text>
            <Text>{"/model [p/m]   open picker or set"}</Text>
            <Text>{"/cancel        cancel auth flow"}</Text>
            <Text>{"/abort         cancel active run"}</Text>
            <Text>{"/clear         new session"}</Text>
            <Text>{"/multiline     toggle multiline (Shift+Enter)"}</Text>
            <Text>{"/exit          quit"}</Text>
            <Text dimColor>
                {"PgUp/PgDn = scroll  Esc = abort/cancel  Ctrl+C = abort/exit"}
            </Text>
        </Box>
    );
}


# ─── main app ────────────────────────────────────────────────────────────────
def:pub app() -> JsxElement {
    boot: any = usePiBoot();
    snap: any = useAgentState();
    auth: any = useAuthFlow();
    ui: any = useExtensionUI();
    messages: any = useMessages();
    tools: any = useToolTimeline();
    streaming: any = useAgentStream();
    session: any = usePiSession();

    has input_text: str = "";
    has multiline: bool = False;
    has show_help: bool = False;
    has scroll_offset: int = 0;

    completions: any = useCompletions(input_text);

    def submit_main(text: str) -> None {
        cmd: str = text.strip();
        if not cmd {
            return;
        }

        if cmd == "/exit" or cmd == "/quit" {
            if session {
                session.dispose();
            }
            exit_app(0);
            return;
        }
        if cmd == "/help" {
            show_help = not show_help;
            return;
        }
        if cmd == "/clear" {
            if session {
                session.clearSession();
            }
            return;
        }
        if cmd == "/abort" {
            if session {
                session.abort();
            }
            return;
        }
        if cmd == "/multiline" {
            multiline = not multiline;
            return;
        }
        if cmd == "/login" {
            if session {
                session.login();
            }
            return;
        }

        if cmd.startswith("/login ") {
            pid: str = cmd[7:].strip();
            if session and pid {
                session.loginWith(pid);
            }
            return;
        }
        if cmd.startswith("/logout ") {
            pid2: str = cmd[8:].strip();
            if session and pid2 {
                session.logout(pid2);
            }
            return;
        }
        if cmd == "/model" {
            if session {
                session.openModelPicker();
            }
            return;
        }
        if cmd.startswith("/model ") {
            spec: str = cmd[7:].strip();
            if "/" in spec {
                parts: list = spec.split("/", 1);
                if session and len(parts) == 2 {
                    session.selectModel(parts[0], parts[1]);
                }
            }
            return;
        }
        if cmd == "/cancel" {
            if session {
                session.cancelLogin();
            }
            return;
        }

        if session {
            session.send(cmd);
        }
    }

    def submit_auth(text: str) -> None {
        step: any = auth.step;
        kind: str = to_str(step.kind);

        if kind == "prompt" or kind == "manual_code" {
            if session {
                session.submitAuthPrompt(text);
            }
            return;
        }
        if kind == "select" {
            value: str = text.strip();
            if value.isdigit() {
                idx: int = int(value) - 1;
                opts: list = list(step.options);
                if 0 <= idx and idx < len(opts) {
                    if session {
                        session.submitAuthSelect(to_str(opts[idx].id));
                    }
                    return;
                }
            }
            if session {
                session.submitAuthSelect(value);
            }
            return;
        }
        if kind == "api_key_input" {
            if session {
                session.submitApiKey(text);
            }
            return;
        }
        if kind == "provider_picker" {
            pid: str = text.strip();
            if session and pid {
                session.loginWith(pid);
            }
            return;
        }
        if kind == "model_picker" {
            spec: str = text.strip();
            if "/" in spec {
                parts2: list = spec.split("/", 1);
                if session and len(parts2) == 2 {
                    session.selectModel(parts2[0], parts2[1]);
                }
            }
            return;
        }
    }

    def submit_dialog(text: str) -> None {
        dialogs: any = ui.dialogs;
        if not dialogs or list_len(dialogs) == 0 {
            return;
        }
        dlg: any = dialogs[0];
        kind3: str = to_str(dlg.kind);
        if kind3 == "select" {
            opts3: list = list(dlg.options) if dlg.options else [];
            value3: str = text.strip();
            if value3.isdigit() {
                idx3: int = int(value3) - 1;
                if 0 <= idx3 and idx3 < len(opts3) {
                    if session {
                        session.resolveDialog(to_str(dlg.id), opts3[idx3]);
                    }
                    return;
                }
            }
            if session {
                session.resolveDialog(to_str(dlg.id), value3);
            }
            return;
        }
        if kind3 == "confirm" {
            ok: bool = text.strip().lower() in ["y", "yes", "true", "1"];
            if session {
                session.resolveDialog(to_str(dlg.id), ok);
            }
            return;
        }
        if session {
            session.resolveDialog(to_str(dlg.id), text);
        }
    }

    def handle_submit() -> None {
        text: str = input_text;
        input_text = "";
        if ui.dialogs and len(list(ui.dialogs)) > 0 {
            submit_dialog(text);
            return;
        }
        if to_str(auth.step.kind) != "idle" {
            submit_auth(text);
            return;
        }
        submit_main(text);
    }

    useInput(
        lambda (ch: str, key: any) -> None {
            if key.escape {
                if ui.dialogs and len(list(ui.dialogs)) > 0 {
                    dlg2: any = list(ui.dialogs)[0];
                    if session {
                        session.resolveDialog(to_str(dlg2.id), None);
                    }
                    input_text = "";
                    return;
                }
                if to_str(auth.step.kind) != "idle" {
                    if session {
                        session.cancelLogin();
                    }
                    input_text = "";
                    return;
                }
                if streaming or (snap and to_str(snap.phase) == "streaming") {
                    if session {
                        session.abort();
                    }
                    return;
                }
            }
            if key.ctrl and ch == "c" {
                if streaming or (snap and to_str(snap.phase) == "streaming") {
                    if session {
                        session.abort();
                    }
                } else {
                    if session {
                        session.dispose();
                    }
                    exit_app(0);
                }
                return;
            }
            if key.return {
                if multiline and key.shift {
                    input_text = input_text + "\n";
                } else {
                    handle_submit();
                }
                return;
            }
            if key.backspace or key.delete {
                input_text = input_text[:-1];
                return;
            }
            if key.pageUp {
                scroll_offset = scroll_offset + 10;
                return;
            }
            if key.pageDown {
                scroll_offset = max(0, scroll_offset - 10);
                return;
            }
            if ch and not key.ctrl and not key.meta {
                input_text = input_text + ch;
            }
        }
    );

    # ─── boot / error screens ─────────────────────────────────────────────
    if (not boot) or (not boot.ready) {
        booting_text: str = "Booting Pi adapter…";
        err: any = boot.error if boot else None;
        return (
            <Box flexDirection="column" padding={1}>
                <Text bold color="magenta">{"Jackal"}</Text>
                <Text dimColor>{booting_text}</Text>
                {err and <Text color="red">{to_str(err)}</Text>}
            </Box>
        );
    }

    # ─── derived display state ────────────────────────────────────────────
    phase: str = to_str(snap.phase) if snap else "ready";
    model_id: str = to_str(snap.model) if snap and snap.model else "(no model)";
    provider_id: str = to_str(snap.provider) if snap and snap.provider else "";
    session_name: str = to_str(snap.sessionName)
        if snap and snap.sessionName
        else "new session";

    phase_color: str = "green";
    if phase == "streaming" {
        phase_color = "cyan";
    } elif phase == "compacting" {
        phase_color = "yellow";
    } elif phase == "retrying" {
        phase_color = "yellow";
    } elif phase == "error" {
        phase_color = "red";
    }

    # transcript with scrollback
    msgs_list: list = list(messages) if messages else [];
    total: int = len(msgs_list);
    end_idx: int = max(1, total - scroll_offset);
    start_idx: int = max(0, end_idx - 20);
    visible_msgs: list = msgs_list[start_idx:end_idx];
    msg_rows: list = [<MessageRow message={m}/> for m in visible_msgs];

    notifs: list = list(ui.notifications) if ui.notifications else [];
    last_notif: any = notifs[-1] if len(notifs) > 0 else None;

    tools_list: list = list(tools) if tools else [];
    running_tools: list = [
        t
        for t in tools_list
        if to_str(t.status) == "running"
    ];
    recent_tools: list = tools_list[-5:] if len(tools_list) > 5 else tools_list;
    tool_rows: list = [<ToolRow tool={t}/> for t in recent_tools];

    auth_kind: str = to_str(auth.step.kind);
    dialogs_list: list = list(ui.dialogs) if ui.dialogs else [];
    has_dialog: bool = len(dialogs_list) > 0;
    completions_list: list = list(completions) if completions else [];
    show_completions: bool = (len(completions_list) > 0) and input_text.startswith("/");

    status_line: str = phase + "  |  msgs=" + str(total) + "  tools_running=" + str(
        len(running_tools)
    ) + "  |  /help";
    header_meta: str = provider_id + ":" + model_id;
    prompt_marker: str = "» " if multiline else "> ";
    divider: str = "─" * 70;

    return (
        <Box flexDirection="column" padding={0}>
            <Box flexDirection="row" justifyContent="space-between" paddingX={1}>
                <Text bold color="magenta">{"Jackal"}</Text>
                <Text color={phase_color}>{phase}</Text>
                <Text dimColor>{header_meta}</Text>
                <Text dimColor>{session_name}</Text>
            </Box>
            <Text color="gray">{divider}</Text>
            <Box flexDirection="column" paddingX={1}>
                {msg_rows}{streaming
                and (
                    <Box>
                        <Text color="magenta" bold>{"⎇ "}</Text>
                        <Text>{to_str(streaming)}</Text>
                        <Text color="cyan">{"▍"}</Text>
                    </Box>
                )}
            </Box>
            {(len(tools_list) > 0)
            and (
                <Box flexDirection="column" paddingX={1} marginTop={1}>
                    <Text dimColor bold>{"Tools"}</Text>
                    {tool_rows}
                </Box>
            )}
            {last_notif
            and (
                <Box paddingX={1}>
                    <Text color="yellow">{"⚠ " + to_str(last_notif.message)}</Text>
                </Box>
            )}
            {(auth_kind == "provider_picker") and <ProviderPicker step={auth.step}/>}
            {(auth_kind == "browser_auth") and <BrowserAuthView step={auth.step}/>}
            {(auth_kind == "prompt")
            and <AuthPromptView step={auth.step} input_text={input_text}/>}
            {(auth_kind == "manual_code")
            and <AuthPromptView step={auth.step} input_text={input_text}/>}
            {(auth_kind == "api_key_input")
            and <AuthPromptView step={auth.step} input_text={input_text}/>}
            {(auth_kind == "select")
            and <AuthPromptView step={auth.step} input_text={input_text}/>}
            {(auth_kind == "model_picker") and <ModelPicker step={auth.step}/>}
            {(auth_kind == "error") and <AuthErrorView step={auth.step}/>}
            {(auth_kind == "logging_in")
            and (
                <Box
                    flexDirection="column"
                    borderStyle="round"
                    borderColor="cyan"
                    paddingX={1}
                >
                    <Text color="cyan">{"⟳ " + to_str(auth.step.status)}</Text>
                </Box>
            )}
            {has_dialog
            and <DialogOverlay dialog={dialogs_list[0]} input_text={input_text}/>}
            {show_help and <HelpPanel/>}
            {(ui.workingVisible and ui.workingMessage)
            and (
                <Box paddingX={1}>
                    <Text color="cyan">{"⟳ " + to_str(ui.workingMessage)}</Text>
                </Box>
            )}
            {show_completions and <CompletionsList items={completions_list}/>}
            <Box borderStyle="single" borderColor="gray" paddingX={1}>
                <Text dimColor>{status_line}</Text>
            </Box>
            <Box paddingX={1}>
                <Text color="green" bold>{prompt_marker}</Text>
                <Text>{input_text}</Text>
                <Text dimColor>{"_"}</Text>
            </Box>
        </Box>
    );
}
