"""Jackal Shell — Ink shell wired to the headless Pi adapter via @jac/pi.
Ported visual design from nanocoder."""

import from "ink" { Box, Text, useInput }
import from "@inkjs/ui" { TextInput, Spinner }
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

# ── Component functions ──────────────────────────────────────────────


# ── welcomemsg.cl.jac ──



def:pub WelcomeMessage(version: str) -> JsxElement {
    return (
        <Box flexDirection="column" marginBottom={1}>
            <Box flexDirection="column">
                <Text color="#e040fb" bold>{"  ██╗ █████╗ ██████╗ ██╗     ██████╗ ███████╗██╗  ██╗"}</Text>
                <Text color="#e040fb" bold>{"  ██║██╔══██╗██╔══██╗██║     ██╔══██╗██╔════╝██║ ██╔╝"}</Text>
                <Text color="#e040fb" bold>{"  ██║███████║██████╔╝██║     ██║  ██║███████╗█████╔╝ "}</Text>
                <Text color="#e040fb" bold>{"  ██║██╔══██║██╔══██╗██║     ██║  ██║╚════██║██╔═██╗ "}</Text>
                <Text color="#e040fb" bold>{"  ██║██║  ██║██████╔╝███████╗██████╔╝███████║██║  ██╗"}</Text>
                <Text color="#e040fb" bold>{"  ╚═╝╚═╝  ╚═╝╚═════╝ ╚══════╝╚═════╝ ╚══════╝╚═╝  ╚═╝"}</Text>
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
                    <Text color="magenta" bold>{"✻ Welcome to Jackal" + (version if version else "") + " ✻"}</Text>
                </Box>
                <Box paddingBottom={1} flexDirection="column">
                    <Text color="gray">{"1. Use natural language to describe your task."}</Text>
                    <Text color="gray">{"2. Ask for file analysis, editing, bash commands and more."}</Text>
                    <Text color="gray">{"3. Be specific for best results."}</Text>
                    <Text color="gray">{"4. Type /help for commands, /exit or Ctrl+C to quit."}</Text>
                </Box>
                <Text color="white">{"/help for help"}</Text>
            </Box>
        </Box>
    );
}

# ── statusbar.cl.jac ──



def phase_color(phase: str) -> str {
    if phase == "streaming" { return "cyan"; }
    if phase == "compacting" { return "yellow"; }
    if phase == "retrying" { return "yellow"; }
    if phase == "error" { return "red"; }
    if phase == "ready" { return "green"; }
    return "gray";
}


def phase_label(phase: str) -> str {
    if phase == "booting" { return "Booting..."; }
    if phase == "ready" { return "Ready"; }
    if phase == "streaming" { return "Thinking"; }
    if phase == "compacting" { return "Compacting"; }
    if phase == "retrying" { return "Retrying"; }
    if phase == "error" { return "Error"; }
    return phase;
}


def:pub StatusBar(
    phase: str,
    model: str,
    provider: str,
    session_name: str,
    context_percent: float,
    mcp_connected: int,
    mcp_total: int,
) -> JsxElement {
    model_display: str = model if model else "(no model)";
    session_display: str = session_name if session_name else "new session";
    pc: str = phase_color(phase);
    pl: str = phase_label(phase);

    has ctx_color: str = "green";
    if context_percent >= 80.0 {
        ctx_color = "yellow";
    }
    elif context_percent >= 60.0 {
        ctx_color = "yellow";
    }

    has ctx_text: str = "Context: " + str(int(context_percent)) + "%";
    if context_percent >= 60.0 {
        ctx_text = ctx_text + " (use /compact)";
    }

    return (
        <Box
            flexDirection="column"
            borderStyle="round"
            borderColor="cyan"
            paddingX={2}
            paddingY={0}
        >
            <Box flexDirection="row" justifyContent="space-between">
                <Box flexDirection="row">
                    <Text color="magenta" bold>{"Jackal"}</Text>
                    <Text>{" "}</Text>
                    <Text color={pc}>{"● " + pl}</Text>
                </Box>
                <Box flexDirection="row">
                    <Text color="green" bold>{provider}</Text>
                    <Text color="gray">{"/"}</Text>
                    <Text color="green">{model_display}</Text>
                </Box>
                <Text color="gray">{session_display}</Text>
            </Box>
            <Box flexDirection="row">
                <Text color={ctx_color}>{ctx_text}</Text>
                {mcp_total > 0 and (
                    <Text color="gray">{"  MCP: " + str(mcp_connected) + "/" + str(mcp_total)}</Text>
                )}
            </Box>
        </Box>
    );
}

# ── usermsg.cl.jac ──



def:pub UserMessage(message: str, tokens: int) -> JsxElement {
    # Simple token estimate
    token_str: str = "~" + str(tokens) if tokens > 0 else "";

    return (
        <Box flexDirection="column">
            <Box marginBottom={1}>
                <Text color="magenta" bold>{"You:"}</Text>
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
                borderLeftColor="magenta"
            >
                <Text>{message}</Text>
            </Box>
            {token_str and (
                <Box marginBottom={1}>
                    <Text color="gray">{token_str + " tokens"}</Text>
                </Box>
            )}
        </Box>
    );
}

# ── streammsg.cl.jac ──



def stream_truncate(text: str, max_lines: int) -> str {
    if not text { return ""; }
    lines: list = text.split("\n");
    if len(lines) <= max_lines { return text; }
    return "…" + "\n".join(lines[-max_lines:]);
}


def stream_estimate_tokens(text: str) -> int {
    if not text { return 0; }
    # Rough estimate: ~4 chars per token
    return int(len(text) / 4);
}


def:pub StreamingMessage(streaming_text: str, model: str) -> JsxElement {
    # Show tail of content to keep render small
    display: str = stream_truncate(streaming_text, 15);
    tokens: int = stream_estimate_tokens(streaming_text);

    return (
        <Box flexDirection="column">
            <Box marginBottom={1} marginTop={1}>
                <Text color="cyan" bold>
                    <Spinner type="dots" /> {" " + (model if model else "Thinking")}
                </Text>
                <Text>
                    {"  ~" + str(tokens) + " tokens"}
                </Text>
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
                borderLeftColor="gray"
            >
                <Text>{display}</Text>
            </Box>
        </Box>
    );
}

# ── asstmsg.cl.jac ──



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
                <Text color="cyan" bold>{(model if model else "Assistant") + ":"}</Text>
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
                borderLeftColor="gray"
            >
                <Text>{display}</Text>
            </Box>
            <Box marginBottom={1}>
                <Text color="gray">{"~" + str(tokens) + " tokens"}</Text>
            </Box>
        </Box>
    );
}

# ── toolline.cl.jac ──



def:pub ToolRow(
    tool_name: str,
    status: str,
    input_preview: str,
) -> JsxElement {
    running: bool = status == "running";
    has color: str = "green";
    if running { color = "yellow"; }
    has icon: str = "✓";
    if running { icon = "⏵"; }
    detail: str = input_preview if input_preview else "";

    # Truncate detail to 60 chars
    if len(detail) > 60 {
        detail = detail[:60] + "…";
    }

    return (
        <Box>
            <Text color={color}>{icon + " "}</Text>
            <Text bold>{tool_name}</Text>
            {detail and <Text dimColor>{"  " + detail}</Text>}
        </Box>
    );
}


def:pub ToolTimeline(
    tool_name_list: list,
    tool_status_list: list,
    tool_input_list: list,
) -> JsxElement {
    # Show last 8 tools
    count: int = len(tool_name_list);
    start: int = 0;
    if count > 8 {
        start = count - 8;
    }

    rows: list = [];
    for i in range(start, count) {
        name: str = "unknown";
        if i < len(tool_name_list) {
            name = tool_name_list[i];
        }
        status: str = "done";
        if i < len(tool_status_list) {
            status = tool_status_list[i];
        }
        input_str: str = "";
        rows.append(
            <ToolRow tool_name={name} status={status} input_preview={input_str}/>
        );
    }

    return (
        <Box flexDirection="column" paddingX={1} marginTop={1}>
            <Text dimColor bold>{"Tools"}</Text>
            {rows}
        </Box>
    );
}

# ── userinput.cl.jac ──



def:pub CompletionList(items: list, selected_index: int) -> JsxElement {
    shown: list = items[:8];
    rows: list = [];
    for (i, s) in enumerate(shown) {
        is_sel: bool = i == selected_index;
        icon: str = "▸ " if is_sel else "  ";
        rows.append(
            <Text color="cyan" bold={is_sel}>{icon + str(s)}</Text>
        );
    }
    return (
        <Box flexDirection="column" marginTop={1}>
            <Text color="gray">{"Available commands:"}</Text>
            {rows}
        </Box>
    );
}


def:pub UserInput(
    input_text: str,
    placeholder: str,
    completions: list,
    completion_index: int,
    disabled: bool,
    on_change: any,
    on_submit: any,
) -> JsxElement {
    is_bash: bool = input_text.startswith("!");
    prompt_text: str = "What would you like me to help with?";
    if is_bash {
        prompt_text = "Bash mode";
    }

    return (
        <Box flexDirection="column">
            {disabled == False and (
                <Text color={ "blue" if is_bash else "magenta"} bold>{prompt_text}</Text>
            )}
            <Box
                flexDirection="column"
                marginTop={1}
                backgroundColor="#1a1a2e"
                padding={1}
                borderStyle="bold"
                borderLeft={true}
                borderRight={false}
                borderTop={false}
                borderBottom={false}
                borderLeftColor={ "blue" if is_bash else "magenta" }
            >
                <Box>
                    {len(input_text) == 0 and <Text color="gray">{"> "}</Text>}
                    <TextInput
                        value={input_text}
                        placeholder={placeholder if placeholder else "/ commands, ! bash"}
                        onChange={on_change}
                        onSubmit={on_submit}
                    />
                </Box>
            </Box>

            {len(completions) > 0 and <CompletionList items={completions} selected_index={completion_index}/>}

            {disabled and (
                <Box paddingY={1} marginTop={1}>
                    <Text color="gray">{"Press Esc to cancel"}</Text>
                </Box>
            )}
        </Box>
    );
}

# ── authflow.cl.jac ──



def:pub ProviderPicker(providers: list) -> JsxElement {
    rows: list = [];
    for p in providers {
        has marker: str = "○";
        has color: str = "yellow";
        if p.get("configured", False) {
            marker = "●";
            color = "green";
        }
        name: str = str(p.get("id", ""));
        display: str = str(p.get("displayName", ""));
        auth_type: str = str(p.get("authType", ""));
        models: str = str(p.get("modelCount", 0));
        rows.append(
            <Box>
                <Text color={color}>{marker + " "}</Text>
                <Text bold>{name}</Text>
                <Text dimColor>{"  " + display + "  (" + auth_type + ", " + models + " models)"}</Text>
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


def:pub BrowserAuthView(url: str, instructions: str) -> JsxElement {
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


def:pub AuthPromptView(message: str, input_text: str, placeholder: str) -> JsxElement {
    msg: str = message if message else "Input required";
    return (
        <Box
            flexDirection="column"
            borderStyle="round"
            borderColor="yellow"
            paddingX={2}
            paddingY={1}
            marginTop={1}
        >
            <Text bold color="yellow">{msg}</Text>
            <Box>
                <Text color="green">{"> "}</Text>
                <Text>{input_text if input_text else ""}</Text>
                <Text dimColor>{"_"}</Text>
            </Box>
            <Text dimColor>{"Enter to submit, Esc to cancel."}</Text>
        </Box>
    );
}


def:pub ModelPicker(models: list, query: str) -> JsxElement {
    filtered: list = [];
    q: str = query.lower() if query else "";
    for m in models {
        label: str = (str(m.get("provider", "")) + "/" + str(m.get("modelId", ""))).lower();
        if not q or q in label {
            filtered.append(m);
        }
    }

    shown: list = filtered[:12];
    rows: list = [
        <Text>{"  " + str(m.get("provider", "")) + "/" + str(m.get("modelId", ""))}</Text>
        for m in shown
    ];
    extra: int = len(filtered) - 12;

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
            {extra > 0 and <Text dimColor>{"  … " + str(extra) + " more"}</Text>}
        </Box>
    );
}


def:pub AuthErrorView(message: str) -> JsxElement {
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

# ── helppanel.cl.jac ──



def:pub HelpPanel() -> JsxElement {
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
                <Text color="white">{"/exit          quit"}</Text>
            </Box>
            <Text dimColor>
                {"↑/↓ = history   Tab = autocomplete   Esc = cancel   Ctrl+C = exit"}
            </Text>
        </Box>
    );
}

# ── Shell helpers ──────────────────────────────────────────────────

