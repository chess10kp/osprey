"""Jackal Shell - Ink shell wired to the headless Jackal adapter via @jac/pi hooks.
Ported visual design from nanocoder."""

import from "ink" { Box, Text, useInput }
import from "@inkjs/ui" { TextInput }
import from "@jac/pi" {
    useJackalBoot,
    useJackalSession,
    useAgentState,
    useAgentStream,
    useMessages,
    useToolTimeline,
    useAuthFlow,
    useJackalUI,
    useCompletions
}

def to_str(value: any) -> str {
    if value is None { return ""; }

    return str(value);
}

def exit_app(code: int) -> None {
    a: int = code;
}

def list_len(value: any) -> int {
    if value is None { return 0; }
    return len(list(value));
}

# ── Welcome banner ──────────────────────────────────────────────────

def:pub WelcomeMessage(props: any) -> JsxElement {
    version: str = to_str(props.version) if props.version else "";
    return (
        <Box flexDirection="column" marginBottom={1}>
            <Box flexDirection="column">
                <Text color="#e040fb" bold>{"     ██╗ █████╗  ██████╗██╗  ██╗ █████╗ ██╗     "}</Text>
                <Text color="#e040fb" bold>{"     ██║██╔══██╗██╔════╝██║ ██╔╝██╔══██╗██║     "}</Text>
                <Text color="#e040fb" bold>{"     ██║███████║██║     █████╔╝ ███████║██║     "}</Text>
                <Text color="#e040fb" bold>{"██   ██║██╔══██║██║     ██╔═██╗ ██╔══██║██║     "}</Text>
                <Text color="#e040fb" bold>{"╚█████╔╝██║  ██║╚██████╗██║  ██╗██║  ██║███████╗"}</Text>
                <Text color="#e040fb" bold>{" ╚════╝ ╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝"}</Text>
            </Box>
            <Box
                flexDirection="column"
                borderStyle="round"
                borderColor="magenta"
                paddingX={2}
                paddingY={1}
                marginBottom={1}
            >
                <Box marginBottom={1}>
                    <Text color="magenta" bold>{"Welcome to Jackal" + (version if version else "") + " -- Jac/Jaseci Coding Agent"}</Text>
                </Box>
                <Box paddingBottom={1} flexDirection="column">
                    <Text color="gray">{"  1. Use natural language to describe your task."}</Text>
                    <Text color="gray">{"  2. Ask for file analysis, editing, bash commands and more."}</Text>
                    <Text color="gray">{"  3. Be specific for best results."}</Text>
                    <Text color="gray">{"  4. Type /help for commands, /exit or Ctrl+C to quit."}</Text>
                </Box>
            </Box>
        </Box>
    );
}

# ── Status bar ──────────────────────────────────────────────────────

def phase_color(phase: str) -> str {
    if phase == "streaming" { return "cyan"; }
    if phase == "compacting" { return "yellow"; }
    if phase == "retrying" { return "yellow"; }
    if phase == "error" { return "red"; }
    if phase == "ready" { return "green"; }
    return "gray";
}

def:pub StatusBar(props: any) -> JsxElement {
    phase: str = to_str(props.phase) if props.phase else "ready";
    model: str = to_str(props.model) if props.model else "";
    provider: str = to_str(props.provider) if props.provider else "";
    session_name: str = to_str(props.session_name) if props.session_name else "";
    msg_count: int = int(props.msg_count) if props.msg_count is not None else 0;
    tools_running: int = int(props.tools_running) if props.tools_running is not None else 0;
    mcp_connected: bool = bool(props.mcp_connected) if props.mcp_connected is not None else False;
    mcp_tools: int = int(props.mcp_tools) if props.mcp_tools is not None else 0;
    pc: str = phase_color(phase);
    model_display: str = model if model else "(no model)";
    provider_display: str = provider if provider else "";
    session_display: str = session_name if session_name else "new session";

    return (
        <Box flexDirection="row" justifyContent="space-between" paddingX={1}>
            <Box flexDirection="row">
                <Text bold color="magenta">{"Jackal"}</Text>
                <Text>{" "}</Text>
                <Text color={pc}>{"● " + phase}</Text>
            </Box>
            <Text color="gray">{"msgs=" + str(msg_count) + "  tools=" + str(tools_running) + "  mcp=" + ("on:" + str(mcp_tools) if mcp_connected else "off")}</Text>
            <Box flexDirection="row">
                <Text color="green" bold>{provider_display}</Text>
                {provider_display and <Text color="gray">{"/"}</Text>}
                <Text color="green">{model_display}</Text>
            </Box>
            <Text color="gray">{session_display}</Text>
        </Box>
    );
}

# ── Message rendering ───────────────────────────────────────────────

def safe_text(msg: any) -> str {
    if not msg { return ""; }

    if hasattr(msg, "text") {
        text_val: any = msg.text;
        if text_val is not None { return str(text_val); }
    }
    if hasattr(msg, "content") {
        content: any = msg.content;
        if content is None { return str(msg); }
        flat: str = str(content);
        if flat and flat != "[object Object]" { return flat; }
        parts: list = [];
        for part in list(content) {
            if hasattr(part, "text") {
                parts.append(str(part.text));
            }
            elif hasattr(part, "get") {
                if str(part.get("type", "")) == "text" {
                    parts.append(str(part.get("text", "")));
                }
            }
        }
        if len(parts) > 0 { return "".join(parts); }
    }
    if hasattr(msg, "keys") {
        if "text" in msg and msg["text"] is not None {
            return str(msg["text"]);
        }
        if "content" in msg and msg["content"] is not None {
            return safe_text({"text": msg["content"], "content": None});
        }
    }
    return str(msg);
}

def msg_role(msg: any) -> str {
    if hasattr(msg, "role") { return str(msg.role); }
    if "role" in msg and hasattr(msg, "keys") and "role" in msg { return str(msg["role"]); }
    return "unknown";
}

def:pub MessageRow(props: any) -> JsxElement {
    msg: any = props.msg;
    role: str = msg_role(msg);
    text: str = safe_text(msg);
    # truncate for display
    display: str = text;
    if len(display) > 500 {
        display = display[:500] + "...";
    }

    if role == "user" {
        return (
            <Box flexDirection="column" paddingX={1}>
                <Text color="green" bold>{"> "}</Text>
                <Text>{display}</Text>
            </Box>
        );
    }
    if role == "assistant" {
        return (
            <Box flexDirection="column" paddingX={1}>
                <Text color="cyan" bold>{"⎇ "}</Text>
                <Text>{display}</Text>
            </Box>
        );
    }
    # system / tool / other
    return (
        <Box flexDirection="column" paddingX={1}>
            <Text dimColor>{"[" + role + "] " + display}</Text>
        </Box>
    );
}

# ── Auth overlays ───────────────────────────────────────────────────

def:pub ProviderPicker(props: any) -> JsxElement {
    step: any = props.step;
    providers: list = list(step.providers) if hasattr(step, "providers") and step.providers else [];
    rows: list = [];
    for p in providers {
        marker: str = "○";
        color: str = "yellow";
        configured: bool = False;
        if hasattr(p, "configured") and p.configured {
            configured = True;
        }
        elif hasattr(p, "get") and p.get("configured", False) {
            configured = True;
        }
        if configured {
            marker = "●";
            color = "green";
        }
        name: str = str(p.get("id", "")) if hasattr(p, "get") else str(getattr(p, "id", ""));
        display: str = str(p.get("displayName", "")) if hasattr(p, "get") else str(getattr(p, "displayName", ""));
        rows.append(
            <Box>
                <Text color={color}>{marker + " "}</Text>
                <Text bold>{name}</Text>
                <Text dimColor>{"  " + display}</Text>
            </Box>
        );
    }

    return (
        <Box
            flexDirection="column"
            borderStyle="round"
            borderColor="cyan"
            paddingX={2}
            paddingY={1}
            marginTop={1}
        >
            <Text bold color="cyan">{"Select a provider"}</Text>
            <Text dimColor>{"Type the id and press Enter. Esc to cancel."}</Text>
            {rows}
        </Box>
    );
}

def:pub BrowserAuthView(props: any) -> JsxElement {
    step: any = props.step;
    url: str = str(getattr(step, "url", "")) if hasattr(step, "url") else "";
    instructions: str = str(getattr(step, "instructions", "")) if hasattr(step, "instructions") else "";
    return (
        <Box
            flexDirection="column"
            borderStyle="round"
            borderColor="#e040fb"
            paddingX={2}
            paddingY={1}
            marginTop={1}
        >
            <Text bold color="#e040fb">{"Browser authentication"}</Text>
            <Text>{"Open in browser:"}</Text>
            <Text color="cyan">{url}</Text>
            {instructions and <Text dimColor>{instructions}</Text>}
            <Text dimColor>{"Esc to cancel."}</Text>
        </Box>
    );
}

def:pub AuthPromptView(props: any) -> JsxElement {
    step: any = props.step;
    input_text: str = to_str(props.input_text) if props.input_text else "";
    message: str = str(getattr(step, "message", "")) if hasattr(step, "message") else "Input required";
    placeholder: str = str(getattr(step, "placeholder", "")) if hasattr(step, "placeholder") else "";
    return (
        <Box
            flexDirection="column"
            borderStyle="round"
            borderColor="yellow"
            paddingX={2}
            paddingY={1}
            marginTop={1}
        >
            <Text bold color="yellow">{message}</Text>
            {placeholder and <Text dimColor>{"(" + placeholder + ")"}</Text>}
            <Box>
                <Text color="green">{"> "}</Text>
                <Text>{input_text if input_text else ""}</Text>
                <Text dimColor>{"_"}</Text>
            </Box>
            <Text dimColor>{"Enter to submit, Esc to cancel."}</Text>
        </Box>
    );
}

def:pub ModelPicker(props: any) -> JsxElement {
    step: any = props.step;
    models: list = list(step.models) if hasattr(step, "models") and step.models else [];
    shown: list = models[:12];
    rows: list = [];
    for m in shown {
        prov: str = str(m.get("provider", "")) if hasattr(m, "get") else str(getattr(m, "provider", ""));
        mid: str = str(m.get("modelId", "")) if hasattr(m, "get") else str(getattr(m, "modelId", ""));
        rows.append(<Text>{"  " + prov + "/" + mid}</Text>);
    }
    extra: int = len(models) - 12;

    return (
        <Box
            flexDirection="column"
            borderStyle="round"
            borderColor="cyan"
            paddingX={2}
            paddingY={1}
            marginTop={1}
        >
            <Text bold color="cyan">{"Select a model"}</Text>
            <Text dimColor>{"Type 'provider/model' and Enter. Esc to cancel."}</Text>
            {rows}
            {extra > 0 and <Text dimColor>{"  ... " + str(extra) + " more"}</Text>}
        </Box>
    );
}

def:pub AuthErrorView(props: any) -> JsxElement {
    step: any = props.step;
    message: str = str(getattr(step, "message", "")) if hasattr(step, "message") else "Unknown error";
    return (
        <Box
            flexDirection="column"
            borderStyle="round"
            borderColor="red"
            paddingX={2}
            paddingY={1}
            marginTop={1}
        >
            <Text bold color="red">{"Auth error"}</Text>
            <Text>{message}</Text>
            <Text dimColor>{"Esc to dismiss. /login to retry."}</Text>
        </Box>
    );
}

# ── Dialog overlay ──────────────────────────────────────────────────

def:pub DialogOption(props: any) -> JsxElement {
    label: str = to_str(props.label) if props.label else "";
    selected: bool = bool(props.selected) if props.selected is not None else False;
    icon: str = "▸ " if selected else "  ";
    return <Text bold={selected}>{icon + label}</Text>;
}

def:pub DialogOverlay(props: any) -> JsxElement {
    dialog: any = props.dialog;
    input_text: str = to_str(props.input_text) if props.input_text else "";
    kind: str = str(getattr(dialog, "kind", ""));
    title: str = str(getattr(dialog, "title", "Dialog"));
    opts: list = [];
    if hasattr(dialog, "options") and dialog.options {
        opts = list(dialog.options);
    }

    return (
        <Box
            flexDirection="column"
            borderStyle="round"
            borderColor="magenta"
            paddingX={2}
            paddingY={1}
            marginTop={1}
        >
            <Text bold color="magenta">{title}</Text>
            {kind == "select" and [
                <Text dimColor>{"Type number or text and Enter."}</Text>,
                [<DialogOption label={str(getattr(o, "label", str(o)))} selected={False}/> for o in opts]
            ]}
            {kind == "confirm" and (
                <Text dimColor>{"y/n + Enter."}</Text>
            )}
            {kind == "input" and (
                <Box>
                    <Text color="green">{"> "}</Text>
                    <Text>{input_text}</Text>
                    <Text dimColor>{"_"}</Text>
                </Box>
            )}
            <Text dimColor>{"Esc to dismiss."}</Text>
        </Box>
    );
}

# ── Completions ─────────────────────────────────────────────────────

def:pub CompletionsList(props: any) -> JsxElement {
    items: list = list(props.items) if props.items else [];
    selected_index: int = int(props.selected_index) if props.selected_index is not None else 0;
    rows: list = [];
    shown: list = items[:8];
    for (i, c) in enumerate(shown) {
        is_sel: bool = i == selected_index;
        icon: str = "▸ " if is_sel else "  ";
        label: str = str(getattr(c, "label", str(c)));
        rows.append(
            <Text color="cyan" bold={is_sel}>{icon + label}</Text>
        );
    }
    return (
        <Box flexDirection="column" paddingX={1}>
            <Text dimColor>{"Completions:"}</Text>
            {rows}
        </Box>
    );
}

# ── Tool rows ───────────────────────────────────────────────────────

def:pub ToolRow(props: any) -> JsxElement {
    tool: any = props.tool;
    name: str = str(getattr(tool, "toolName", getattr(tool, "name", "unknown")));
    status: str = str(getattr(tool, "status", "done"));
    running: bool = status == "running";
    color: str = "yellow" if running else "green";
    icon: str = "⏵" if running else "✓";
    duration_ms: any = getattr(tool, "durationMs", None);
    duration_label: str = "";
    if duration_ms is not None {
        duration_label = "  (" + str(duration_ms) + "ms)";
    }
    result_text: str = to_str(getattr(tool, "result", ""));
    if len(result_text) > 120 {
        result_text = result_text[:120] + "...";
    }

    return (
        <Box flexDirection="column">
            <Box>
                <Text color={color}>{icon + " "}</Text>
                <Text bold>{name}</Text>
                {duration_label and <Text dimColor>{duration_label}</Text>}
            </Box>
            {result_text and <Text dimColor>{"  " + result_text}</Text>}
        </Box>
    );
}

# ── Help panel ──────────────────────────────────────────────────────

def:pub HelpPanel(_props: any) -> JsxElement {
    return (
        <Box
            flexDirection="column"
            borderStyle="round"
            borderColor="cyan"
            paddingX={2}
            paddingY={1}
            marginTop={1}
        >
            <Text bold color="cyan">{"Commands"}</Text>
            <Box flexDirection="column" marginTop={1}>
                <Text color="white">{"/help          toggle this panel"}</Text>
                <Text color="white">{"/login [p]     start auth flow"}</Text>
                <Text color="white">{"/logout <p>    logout provider"}</Text>
                <Text color="white">{"/model [p/m]   open picker or set"}</Text>
                <Text color="white">{"/cancel        cancel auth flow"}</Text>
                <Text color="white">{"/abort         cancel active run"}</Text>
                <Text color="white">{"/clear,/new    new session"}</Text>
                <Text color="white">{"/multiline     toggle multiline mode"}</Text>
                <Text color="white">{"/compact       compact context"}</Text>
                <Text color="white">{"/jac-check     run jac check"}</Text>
                <Text color="white">{"/jac-doctor    environment diagnostics"}</Text>
                <Text color="white">{"/jac <args>    run jac cli via tool"}</Text>
                <Text color="white">{"/fix           jac check/fix loop"}</Text>
                <Text color="white">{"/create        list jac templates"}</Text>
                <Text color="white">{"/create <tpl> [name]  run jac create"}</Text>
                <Text color="white">{"/exit          quit"}</Text>
            </Box>
            <Text dimColor>
                {"Esc = cancel   Tab = autocomplete   Ctrl+C = exit"}
            </Text>
        </Box>
    );
}

# ── Main app ────────────────────────────────────────────────────────

def:pub app() -> JsxElement {
    boot: any = useJackalBoot();
    snap: any = useAgentState();
    auth: any = useAuthFlow();
    ui: any = useJackalUI();
    messages: any = useMessages();
    tools: any = useToolTimeline();
    streaming: any = useAgentStream();
    session: any = useJackalSession();

    has input_text: str = "";
    has input_reset_key: int = 0;
    has multiline: bool = False;
    has show_help: bool = False;
    has scroll_offset: int = 0;
    has selected_completion_index: int = 0;

    completions: any = useCompletions(input_text);

    # Derived from snap - plain locals, not has (would call setState during render)
    phase: any = "ready";
    if snap { phase = to_str(snap.phase); }
    model_id: any = "(no model)";
    if snap and snap.model { model_id = to_str(snap.model); }
    provider_id: any = "";
    if snap and snap.provider { provider_id = to_str(snap.provider); }
    session_name: any = "new session";
    if snap and snap.sessionName { session_name = to_str(snap.sessionName); }


    def submit_main(text: str) -> None {
        cmd: str = text.strip();
        if not cmd { return; }

        if cmd == "/exit" or cmd == "/quit" {
            if session { session.dispose(); }
            exit_app(0);
            return;
        }
        if cmd == "/help" {
            show_help = not show_help;
            return;
        }
        if cmd == "/clear" or cmd == "/new" {
            if session { session.clearSession(); }
            return;
        }
        if cmd == "/abort" {
            if session { session.abort(); }
            return;
        }
        if cmd == "/multiline" {
            multiline = not multiline;
            return;
        }
        if cmd == "/compact" {
            if session and hasattr(session, "compactSession") { session.compactSession(); }
            elif session { session.send("Compact the conversation context now. Use the compact_context tool."); }
            return;
        }
        if cmd == "/jac-check" {
            if session and hasattr(session, "runTool") { session.runTool("jac_check", {}); }
            elif session { session.send("Use jac_check tool and report diagnostics."); }
            return;
        }
        if cmd == "/jac-doctor" {
            if session and hasattr(session, "runTool") { session.runTool("jac_doctor", {}); }
            elif session { session.send("Use jac_doctor tool and summarize findings."); }
            return;
        }
        if cmd.startswith("/jac ") {
            tail: str = cmd[5:].strip();
            if session and tail {
                parts_jac: list = tail.split(" ");
                if hasattr(session, "runTool") { session.runTool("jac_cli", {"args": parts_jac}); }
                else { session.send("Use jac_cli with args split from: " + tail); }
            }
            return;
        }
        if cmd == "/fix" {
            if session and hasattr(session, "runFixFlow") { session.runFixFlow(3); }
            elif session and hasattr(session, "runTool") { session.runTool("jac_fix", {"maxAttempts": 3}); }
            elif session { session.send("Use jac_fix tool with maxAttempts=3 and summarize the result."); }
            return;
        }
        if cmd == "/create" {
            if session and hasattr(session, "runTool") { session.runTool("jac_list_templates", {}); }
            elif session { session.send("Use jac_list_templates and show available templates."); }
            return;
        }
        if cmd.startswith("/create ") {
            arg: str = cmd[8:].strip();
            if session and arg {
                parts: list = arg.split(" ");
                tpl: str = parts[0] if len(parts) > 0 else "";
                name: str = parts[1] if len(parts) > 1 else "";
                if tpl and name {
                    if hasattr(session, "runTool") { session.runTool("jac_create", {"template": tpl, "name": name}); }
                    else { session.send("Use jac_create with template='" + tpl + "' and name='" + name + "'."); }
                } elif tpl {
                    if hasattr(session, "runTool") { session.runTool("jac_create", {"template": tpl}); }
                    else { session.send("Use jac_create with template='" + tpl + "'."); }
                }
            }
            return;
        }
        if cmd == "/login" {
            if session { session.login(); }
            return;
        }
        if cmd.startswith("/login ") {
            pid: str = cmd[7:].strip();
            if session and pid { session.loginWith(pid); }
            return;
        }
        if cmd.startswith("/logout ") {
            pid2: str = cmd[8:].strip();
            if session and pid2 { session.logout(pid2); }
            return;
        }
        if cmd == "/model" {
            if session { session.openModelPicker(); }
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
            if session { session.cancelLogin(); }
            return;
        }
        if session { session.send(cmd); }
    }

    def submit_auth(text: str) -> None {
        step: any = auth.step;
        kind: any = "idle";
        if step { kind = to_str(step.kind); }

        if kind == "prompt" or kind == "manual_code" {
            if session { session.submitAuthPrompt(text); }
            return;
        }
        if kind == "select" {
            value: str = text.strip();
            if value.isdigit() {
                idx: int = int(value) - 1;
                opts: list = list(step.options);
                if 0 <= idx and idx < len(opts) {
                    if session { session.submitAuthSelect(to_str(opts[idx].id)); }
                    return;
                }
            }
            if session { session.submitAuthSelect(value); }
            return;
        }
        if kind == "api_key_input" {
            if session { session.submitApiKey(text); }
            return;
        }
        if kind == "provider_picker" {
            pid: str = text.strip();
            if session and pid { session.loginWith(pid); }
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
        if not dialogs or list_len(dialogs) == 0 { return; }
        dlg: any = dialogs[0];
        kind3: any = "";
        if dlg { kind3 = to_str(dlg.kind); }
        if kind3 == "select" {
            opts3: list = list(dlg.options) if dlg.options else [];
            value3: str = text.strip();
            if value3.isdigit() {
                idx3: int = int(value3) - 1;
                if 0 <= idx3 and idx3 < len(opts3) {
                    if session { session.resolveDialog(to_str(dlg.id), opts3[idx3]); }
                    return;
                }
            }
            if session { session.resolveDialog(to_str(dlg.id), value3); }
            return;
        }
        if kind3 == "confirm" {
            ok: bool = text.strip().lower() in ["y", "yes", "true", "1"];
            if session { session.resolveDialog(to_str(dlg.id), ok); }
            return;
        }
        if session { session.resolveDialog(to_str(dlg.id), text); }
    }

    def handle_submit(submitted: str = "") -> None {
        text: str = submitted.strip() if submitted else input_text.strip();
        input_text = "";
        input_reset_key = input_reset_key + 1;
        if not text { return; }
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
                    if session { session.resolveDialog(to_str(dlg2.id), None); }
                    input_text = "";
                    input_reset_key = input_reset_key + 1;
                    return;
                }
                if to_str(auth.step.kind) != "idle" {
                    if session { session.cancelLogin(); }
                    input_text = "";
                    input_reset_key = input_reset_key + 1;
                    return;
                }
                if streaming or (snap and to_str(snap.phase) == "streaming") {
                    if session { session.abort(); }
                    return;
                }
            }
            if key.ctrl and ch == "d" {
                if multiline {
                    handle_submit();
                    return;
                }
            }
            if key.ctrl and ch == "c" {
                if streaming or (snap and to_str(snap.phase) == "streaming") {
                    if session { session.abort(); }
                } else {
                    if session { session.dispose(); }
                    exit_app(0);
                }
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
            completion_items: list = list(completions) if completions else [];
            completion_count: int = len(completion_items);
            if key.upArrow and completion_count > 0 {
                selected_completion_index = (selected_completion_index - 1 + completion_count) % completion_count;
                return;
            }
            if key.downArrow and completion_count > 0 {
                selected_completion_index = (selected_completion_index + 1) % completion_count;
                return;
            }
            if key.tab and completion_count > 0 {
                idx: any = selected_completion_index;
                if idx < 0 or idx >= completion_count { idx = 0; }
                input_text = str(completion_items[idx].value);
                input_reset_key = input_reset_key + 1;
                return;
            }
        }
    );

    # ─── boot / error screens ─────────────────────────────────────────
    if (not boot) or (not boot.ready) {
        booting_text: str = "Booting Jackal adapter...";
        err: any = boot.error if boot else None;
        return (
            <Box flexDirection="column" padding={1}>
                <Text bold color="magenta">{"Jackal"}</Text>
                <Text dimColor>{booting_text}</Text>
                {err and <Text color="red">{to_str(err)}</Text>}
            </Box>
        );
    }

    pc: str = phase_color(str(phase));

    # transcript with scrollback
    msgs_list: list = list(messages) if messages else [];
    total: int = len(msgs_list);
    end_idx: int = max(1, total - scroll_offset);
    start_idx: int = max(0, end_idx - 20);
    visible_msgs: list = msgs_list[start_idx:end_idx];
    msg_rows: list = [<MessageRow msg={m}/> for m in visible_msgs];

    notifs: list = list(ui.notifications) if ui.notifications else [];
    last_notif: any = notifs[-1] if len(notifs) > 0 else None;
    mcp_error: str = to_str(getattr(snap, "mcpError", "")) if snap else "";

    tools_list: list = list(tools) if tools else [];
    running_tools: list = [
        t for t in tools_list if to_str(t.status) == "running"
    ];
    recent_tools: list = tools_list[-5:] if len(tools_list) > 5 else tools_list;
    tool_rows: list = [<ToolRow tool={t}/> for t in recent_tools];

    auth_kind: any = "idle";
    if auth and auth.step { auth_kind = to_str(auth.step.kind); }
    dialogs_list: list = list(ui.dialogs) if ui.dialogs else [];
    has_dialog: bool = len(dialogs_list) > 0;
    completions_list: list = list(completions) if completions else [];
    show_completions: bool = len(completions_list) > 0;
    completion_selection: int = selected_completion_index;
    if len(completions_list) > 0 {
        if completion_selection < 0 or completion_selection >= len(completions_list) {
            completion_selection = 0;
        }
    } else {
        completion_selection = 0;
    }

    divider: str = "-" * 70;
    prompt_marker: str = ">> " if multiline else "> ";
    is_streaming: bool = (streaming is not None and to_str(streaming) != "") or phase == "streaming";

    # Welcome banner disabled.
    show_welcome: bool = False;

    return (
        <Box flexDirection="column" padding={0}>
            <StatusBar
                phase={phase}
                model={model_id}
                provider={provider_id}
                session_name={session_name}
                msg_count={total}
                tools_running={len(running_tools)}
                mcp_connected={bool(getattr(snap, "mcpConnected", False))}
                mcp_tools={int(getattr(snap, "mcpToolCount", 0))}
            />
            <Text color="gray">{divider}</Text>
            <Box flexDirection="column" paddingX={1}>
                {msg_rows}
                {is_streaming and (
                    <Box>
                        <Text color="cyan" bold>{"⎇ "}</Text>
                        <Text>{to_str(streaming)}</Text>
                        <Text color="cyan">{"_"}</Text>
                    </Box>
                )}
            </Box>
            {len(tools_list) > 0 and (
                <Box flexDirection="column" paddingX={1} marginTop={1}>
                    <Text dimColor bold>{"Tools"}</Text>
                    {tool_rows}
                </Box>
            )}
            {last_notif and (
                <Box paddingX={1}>
                    <Text color="yellow">{"! "}</Text>
                    <Text color="yellow">{to_str(last_notif.message)}</Text>
                </Box>
            )}
            {mcp_error and (
                <Box paddingX={1}>
                    <Text color="red">{"mcp error: " + mcp_error}</Text>
                </Box>
            )}
            {auth_kind == "provider_picker" and <ProviderPicker step={auth.step}/>}
            {auth_kind == "browser_auth" and <BrowserAuthView step={auth.step}/>}
            {(auth_kind == "prompt" or auth_kind == "manual_code" or auth_kind == "api_key_input" or auth_kind == "select")
                and <AuthPromptView step={auth.step} input_text={input_text}/>}
            {auth_kind == "model_picker" and <ModelPicker step={auth.step}/>}
            {auth_kind == "error" and <AuthErrorView step={auth.step}/>}
            {auth_kind == "logging_in" and (
                <Box flexDirection="column" borderStyle="round" borderColor="cyan" paddingX={1}>
                    <Text color="cyan">{"(loading) "}</Text>
                    <Text color="cyan">{to_str(auth.step.status)}</Text>
                </Box>
            )}
            {has_dialog and <DialogOverlay dialog={dialogs_list[0]} input_text={input_text}/>}
            {show_help and <HelpPanel/>}
            {ui.workingVisible and ui.workingMessage and (
                <Box paddingX={1}>
                    <Text color="cyan">{"(working) "}</Text>
                    <Text color="cyan">{to_str(ui.workingMessage)}</Text>
                </Box>
            )}
            <Box paddingX={1} marginTop={1}>
                <Text color="green" bold>{prompt_marker}</Text>
                <TextInput
                    key={str(input_reset_key)}
                    defaultValue={input_text}
                    placeholder={"Type a message (or /help)" if multiline == False else "Multiline (Ctrl+D to send)"}
                    onChange={lambda (v: str) -> None {
                        input_text = v;
                        selected_completion_index = 0;
                    }}
                    onSubmit={lambda (v: str) -> None {
                        if multiline {
                            input_text = v + "\n";
                            input_reset_key = input_reset_key + 1;
                        } else {
                            handle_submit(v);
                        }
                    }}
                />
            </Box>
            {show_completions and <CompletionsList items={completions_list} selected_index={completion_selection}/>}
        </Box>
    );
}
