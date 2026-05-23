"""Jackal Shell - Ink shell wired to the headless Jackal adapter via @jac/pi hooks.
Ported visual design from nanocoder."""

import from "ink" { Box, Text, useInput }
import from "./components/chathistory.cl.jac" { ChatHistory }
import from "./components/streammsg.cl.jac" { StreamingMessage }
import from "./jac_pi_runtime_shim.mjs" {
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

def mode_color(mode: str) -> str {
    if mode == "yolo" { return "red"; }
    if mode == "plan" { return "yellow"; }
    if mode == "auto-accept" { return "cyan"; }
    return "gray";
}

def:pub StatusBar(props: any) -> JsxElement {
    phase: str = to_str(props.phase) if props.phase else "ready";
    mode: str = to_str(props.mode) if props.mode else "normal";
    model: str = to_str(props.model) if props.model else "";
    provider: str = to_str(props.provider) if props.provider else "";
    session_name: str = to_str(props.session_name) if props.session_name else "";
    msg_count: int = int(props.msg_count) if props.msg_count is not None else 0;
    tools_running: int = int(props.tools_running) if props.tools_running is not None else 0;
    mcp_connected: bool = bool(props.mcp_connected) if props.mcp_connected is not None else False;
    mcp_connecting: bool = bool(props.mcp_connecting) if props.mcp_connecting is not None else False;
    mcp_tools: int = int(props.mcp_tools) if props.mcp_tools is not None else 0;
    usage_line: str = to_str(props.usage_line) if props.usage_line else "";
    pc: str = phase_color(phase);
    mc: str = mode_color(mode);
    model_display: str = model if model else "(no model)";
    provider_display: str = provider if provider else "";
    session_display: str = session_name if session_name else "new session";
    mcp_label: str = "on:" + str(mcp_tools);
    if mcp_connecting { mcp_label = "connecting"; }
    elif not mcp_connected { mcp_label = "off"; }

    return (
        <Box flexDirection="row" justifyContent="space-between" paddingX={1}>
            <Box flexDirection="row">
                <Text bold color="magenta">{"Jackal"}</Text>
                <Text>{" "}</Text>
                <Text color={pc}>{"● " + phase}</Text>
                <Text>{" "}</Text>
                <Text color={mc} bold>{mode}</Text>
            </Box>
            <Text color="gray">{"msgs=" + str(msg_count) + "  tools=" + str(tools_running) + "  mcp=" + mcp_label}</Text>
            <Box flexDirection="row">
                <Text color="green" bold>{provider_display}</Text>
                {provider_display and <Text color="gray">{"/"}</Text>}
                <Text color="green">{model_display}</Text>
            </Box>
            <Text color="gray">{session_display}</Text>
            {usage_line and <Text color="gray">{"  " + usage_line}</Text>}
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
            {len(models) > 0 and <Text dimColor>{str(len(models)) + " models available (shown in completions below)."}</Text>}
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
    compact: bool = bool(props.compact) if props.compact is not None else False;
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
    input_obj: any = getattr(tool, "input", None);
    input_preview: str = "";
    if input_obj is not None {
        input_preview = str(input_obj);
        if len(input_preview) > 80 { input_preview = input_preview[:80] + "..."; }
    }
    result_text: str = to_str(getattr(tool, "result", ""));
    if compact and len(result_text) > 80 {
        result_text = result_text[:80] + "...";
    } elif (not compact) and len(result_text) > 2000 {
        result_text = result_text[:2000] + "\n...[truncated]";
    } elif compact and len(result_text) > 0 {
        result_text = "";
    }

    return (
        <Box flexDirection="column">
            <Box>
                <Text color={color}>{icon + " "}</Text>
                <Text bold>{name}</Text>
                {duration_label and <Text dimColor>{duration_label}</Text>}
            </Box>
            {input_preview and <Text dimColor>{"  args: " + input_preview}</Text>}
            {result_text and <Text dimColor>{"  " + result_text}</Text>}
        </Box>
    );
}

def:pub ApprovalBanner(props: any) -> JsxElement {
    pending: any = props.pending;
    if not pending { return <Text></Text>; }
    tool_name: str = to_str(getattr(pending, "toolName", "tool"));
    return (
        <Box flexDirection="column" borderStyle="round" borderColor="yellow" paddingX={1} marginTop={1}>
            <Text bold color="yellow">{"Tool approval required"}</Text>
            <Text>{"Tool: " + tool_name}</Text>
            <Text dimColor>{"Enter = approve   Esc = reject   Shift+Tab = change mode"}</Text>
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
                <Text color="white">{"Ctrl+J / Shift+Enter  insert newline"}</Text>
                <Text color="white">{"/compact       compact context"}</Text>
                <Text color="white">{"/usage         context utilization"}</Text>
                <Text color="white">{"/resume [id]   load prior session"}</Text>
                <Text color="white">{"/checkpoint    snapshot files + chat"}</Text>
                <Text color="white">{"/tasks         task list"}</Text>
                <Text color="white">{"/jac-check     run jac check"}</Text>
                <Text color="white">{"/jac-doctor    environment diagnostics"}</Text>
                <Text color="white">{"/jac <args>    run jac cli via tool"}</Text>
                <Text color="white">{"/fix           jac check/fix loop"}</Text>
                <Text color="white">{"/osp <desc>    OSP graph design"}</Text>
                <Text color="white">{"/create        list jac templates"}</Text>
                <Text color="white">{"/agents        list subagents"}</Text>
                <Text color="white">{"/exit          quit"}</Text>
            </Box>
            <Text dimColor>
                {"Keys: Shift+Tab mode  Esc abort/clear  Ctrl+O compact tools  Ctrl+J newline  @file  !cmd"}
            </Text>
        </Box>
    );
}

# ── Prompt input ────────────────────────────────────────────────────

def:pub PromptBar(props: any) -> JsxElement {
    prompt_marker: str = props.prompt_marker;
    input_text: str = props.input_text;
    input_cursor: int = props.input_cursor;
    show_completions: bool = props.show_completions;
    completions_list: list = props.completions_list;
    completion_selection: int = props.completion_selection;

    cur: int = max(0, min(input_cursor, len(input_text)));
    before: str = input_text[:cur];
    at: str = input_text[cur:cur + 1] if cur < len(input_text) else "";
    after: str = input_text[cur + 1:] if cur < len(input_text) else "";

    return (
        <Box flexDirection="column" paddingX={1} marginTop={1}>
            <Box borderStyle="single" borderColor="gray" paddingX={1}>
                {prompt_marker and <Text color="green" bold>{prompt_marker}</Text>}
                {prompt_marker and <Text>{" "}</Text>}
                <Box>
                    <Text>{before}</Text>
                    <Text inverse>{at if at else " "}</Text>
                    <Text>{after}</Text>
                </Box>
                {len(input_text) == 0 and <Text color="gray">{" Type a message (Enter=send, Ctrl+J=newline, /help)"}</Text>}
            </Box>
            {show_completions and <CompletionsList items={completions_list} selected_index={completion_selection}/>}
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
    has input_cursor: int = 0;
    has input_reset_key: int = 0;
    # multiline is always enabled -- Enter submits, Ctrl+J / Shift+Enter inserts newline
    has show_help: bool = False;
    has selected_completion_index: int = 0;
    has compact_tools: bool = False;

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
    dev_mode: any = "normal";
    if snap and snap.mode { dev_mode = to_str(snap.mode); }
    pending_approval: any = None;
    if snap and snap.pendingApproval { pending_approval = snap.pendingApproval; }
    usage_line: str = "";
    if session and hasattr(session, "getUsageLine") {
        usage_line = to_str(session.getUsageLine());
    }


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
            show_help = False;
            selected_completion_index = 0;
            if session { session.clearSession(); }
            return;
        }
        if cmd == "/abort" {
            if session { session.abort(); }
            return;
        }

        if cmd == "/compact" or cmd.startswith("/compact ") {
            if session and hasattr(session, "compactSession") {
                session.compactSession();
            }
            return;
        }
        if cmd == "/usage" {
            if session and hasattr(session, "getUsageLine") {
                session.send("[usage] " + session.getUsageLine());
            }
            return;
        }
        if cmd == "/resume" {
            if session and hasattr(session, "showSessions") { session.showSessions(); }
            return;
        }
        if cmd.startswith("/resume ") {
            target: str = cmd[8:].strip();
            if session and hasattr(session, "resumeSession") { session.resumeSession(target); }
            return;
        }
        if cmd.startswith("/rename ") {
            new_name: str = cmd[8:].strip();
            if session and new_name and hasattr(session, "renameSession") { session.renameSession(new_name); }
            return;
        }
        if cmd == "/export" {
            if session and hasattr(session, "exportSessionMarkdown") {
                md: str = session.exportSessionMarkdown();
                session.send("[export]\n" + md[:4000]);
            }
            return;
        }
        if cmd.startswith("/checkpoint") {
            if not session { return; }
            cp_parts: list = cmd.split(" ");
            if len(cp_parts) == 1 or (len(cp_parts) > 1 and cp_parts[1] == "list") {
                if hasattr(session, "showCheckpoints") { session.showCheckpoints(); }
                return;
            }
            sub: str = cp_parts[1] if len(cp_parts) > 1 else "";
            if sub == "create" {
                cname: str = " ".join(cp_parts[2:]) if len(cp_parts) > 2 else "";
                if hasattr(session, "checkpointCreate") { session.checkpointCreate(cname if cname else None); }
            } elif sub == "load" and len(cp_parts) > 2 and hasattr(session, "checkpointLoad") {
                session.checkpointLoad(cp_parts[2]);
            } elif sub == "delete" and len(cp_parts) > 2 and hasattr(session, "checkpointDelete") {
                session.checkpointDelete(cp_parts[2]);
            }
            return;
        }
        if cmd.startswith("/tasks") {
            if not session { return; }
            tp: list = cmd.split(" ", 2);
            if len(tp) == 1 or tp[1] == "list" {
                if hasattr(session, "showTasks") { session.showTasks(); }
                return;
            }
            if tp[1] == "add" and len(tp) > 2 and hasattr(session, "tasksAdd") {
                session.tasksAdd(tp[2]);
            } elif tp[1] == "remove" and len(tp) > 2 and hasattr(session, "tasksRemove") {
                session.tasksRemove(int(tp[2]));
            } elif tp[1] == "clear" and hasattr(session, "tasksClear") {
                session.tasksClear();
            }
            return;
        }
        if cmd == "/mcp" {
            mcp_on: bool = bool(getattr(snap, "mcpConnected", False)) if snap else False;
            mcp_n: int = int(getattr(snap, "mcpToolCount", 0)) if snap else 0;
            session.send("[mcp] connected=" + str(mcp_on) + " tools=" + str(mcp_n));
            return;
        }
        if cmd.startswith("/osp") {
            desc: str = cmd[4:].strip() if len(cmd) > 4 else "";
            if session and desc and hasattr(session, "runOsp") { session.runOsp(desc); }
            elif session and not desc { session.send("Usage: /osp <domain description>"); }
            return;
        }
        if cmd.startswith("/jac convert-python") {
            py_path: str = cmd[21:].strip();
            if session and py_path and hasattr(session, "runConvertPython") { session.runConvertPython(py_path); }
            return;
        }
        if cmd.startswith("/jac review-idioms") {
            rest: str = cmd[18:].strip();
            paths: list = rest.split(" ") if rest else [];
            if session and hasattr(session, "runIdiomReview") { session.runIdiomReview(paths); }
            return;
        }
        if cmd == "/jac-check" {
            if session and hasattr(session, "runTool") { session.runTool("jac_check", {}); }
            elif session { session.send("Use jac_check tool and report diagnostics."); }
            return;
        }
        if cmd == "/jac-doctor" {
            if session and hasattr(session, "showJacDoctor") { session.showJacDoctor(); }
            elif session and hasattr(session, "runJacDoctor") { session.runJacDoctor(); }
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
        if cmd == "/agents" {
            if session and hasattr(session, "showAgents") { session.showAgents(); }
            return;
        }
        if cmd == "/commands" {
            if session and hasattr(session, "showCommands") { session.showCommands(); }
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
        input_cursor = 0;
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
                if pending_approval and session {
                    session.rejectTool();
                    return;
                }
                if ui.dialogs and len(list(ui.dialogs)) > 0 {
                    dlg2: any = list(ui.dialogs)[0];
                    if session { session.resolveDialog(to_str(dlg2.id), None); }
                    input_text = "";
                    input_cursor = 0;
                    input_reset_key = input_reset_key + 1;
                    return;
                }
                if to_str(auth.step.kind) != "idle" {
                    if session { session.cancelLogin(); }
                    input_text = "";
                    input_cursor = 0;
                    input_reset_key = input_reset_key + 1;
                    return;
                }
                if streaming or (snap and to_str(snap.phase) == "streaming") {
                    if session { session.abort(); }
                    return;
                }
                if len(input_text) > 0 {
                    input_text = "";
                    input_cursor = 0;
                    input_reset_key = input_reset_key + 1;
                    return;
                }
                return;
            }
            if key.shift and key.tab {
                if session and hasattr(session, "cycleMode") { session.cycleMode(); }
                return;
            }
            if key.ctrl and ch == "o" {
                compact_tools = not compact_tools;
                return;
            }
            if key.ctrl and ch == "d" {
                if len(input_text) > 0 and input_cursor < len(input_text) {
                    input_text = input_text[:input_cursor] + input_text[input_cursor + 1:];
                    return;
                }
            }
            if key.ctrl and ch == "c" {
                submit_main("/exit");
                return;
            }
            if key.pageUp or key.pageDown {
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
                completed: str = str(completion_items[idx].value);
                input_text = completed;
                input_cursor = len(completed);
                selected_completion_index = 0;
                input_reset_key = input_reset_key + 1;
                return;
            }
            # Insert newline: Ctrl+J, raw \n without key.return, or Shift+Enter
            # (Matches nanocoder's always-available multiline input behavior)
            if (key.ctrl and ch == "j") or (ch == "\n" and not key.return) or (key.return and key.shift) {
                input_text = input_text[:input_cursor] + "\n" + input_text[input_cursor:];
                input_cursor = input_cursor + 1;
                return;
            }
            if key.return {
                if pending_approval and session {
                    session.approveTool();
                    return;
                }
                use_selected_completion: bool = False;
                if completion_count > 0 {
                    if not input_text.strip() {
                        use_selected_completion = True;
                    } elif to_str(auth.step.kind) == "model_picker" and "/" not in input_text.strip() {
                        use_selected_completion = True;
                    }
                }
                if use_selected_completion {
                    idx_enter: int = selected_completion_index;
                    if idx_enter < 0 or idx_enter >= completion_count { idx_enter = 0; }
                    handle_submit(str(completion_items[idx_enter].value));
                    return;
                }
                handle_submit();
                return;
            }
            if key.leftArrow {
                input_cursor = max(0, input_cursor - 1);
                return;
            }
            if key.rightArrow {
                input_cursor = min(len(input_text), input_cursor + 1);
                return;
            }
            if key.ctrl and ch == "a" {
                input_cursor = 0;
                return;
            }
            if key.ctrl and ch == "e" {
                input_cursor = len(input_text);
                return;
            }
            if key.ctrl and ch == "k" {
                input_text = input_text[:input_cursor];
                return;
            }
            if key.ctrl and ch == "u" {
                input_text = input_text[input_cursor:];
                input_cursor = 0;
                return;
            }
            if key.ctrl and ch == "w" {
                s: int = input_cursor;
                while s > 0 and input_text[s - 1].isspace() { s = s - 1; }
                while s > 0 and not input_text[s - 1].isspace() { s = s - 1; }
                input_text = input_text[:s] + input_text[input_cursor:];
                input_cursor = s;
                return;
            }
            if key.meta and ch == "b" {
                s2: int = input_cursor;
                while s2 > 0 and input_text[s2 - 1].isspace() { s2 = s2 - 1; }
                while s2 > 0 and not input_text[s2 - 1].isspace() { s2 = s2 - 1; }
                input_cursor = s2;
                return;
            }
            if key.meta and ch == "f" {
                e2: int = input_cursor;
                while e2 < len(input_text) and not input_text[e2].isspace() { e2 = e2 + 1; }
                while e2 < len(input_text) and input_text[e2].isspace() { e2 = e2 + 1; }
                input_cursor = e2;
                return;
            }
            if key.backspace {
                if input_cursor > 0 {
                    input_text = input_text[:input_cursor - 1] + input_text[input_cursor:];
                    input_cursor = input_cursor - 1;
                }
                return;
            }
            if key.delete {
                if input_cursor < len(input_text) {
                    input_text = input_text[:input_cursor] + input_text[input_cursor + 1:];
                }
                return;
            }
            if len(ch) > 0 and not key.ctrl and not key.meta {
                input_text = input_text[:input_cursor] + ch + input_text[input_cursor:];
                input_cursor = input_cursor + len(ch);
                selected_completion_index = 0;
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

    msgs_list: list = list(messages) if messages else [];
    total: int = len(msgs_list);
    transcript_epoch: int = 0;
    if snap and hasattr(snap, "transcriptEpoch") {
        transcript_epoch = int(snap.transcriptEpoch);
    }

    notifs: list = list(ui.notifications) if ui.notifications else [];
    last_notif: any = notifs[-1] if len(notifs) > 0 else None;
    mcp_error: str = to_str(getattr(snap, "mcpError", "")) if snap else "";

    tools_list: list = list(tools) if tools else [];
    running_tools: list = [
        t for t in tools_list if to_str(t.status) == "running"
    ];
    recent_tools: list = tools_list[-5:] if len(tools_list) > 5 else tools_list;
    tool_rows: list = [<ToolRow tool={t} compact={compact_tools}/> for t in recent_tools];

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
    prompt_marker: str = "";
    is_streaming: bool = streaming is not None or phase == "streaming";

    live_component: any = None;
    if is_streaming {
        live_component = <StreamingMessage streaming_text={to_str(streaming)} model={model_id}/>;
    }

    # Welcome banner disabled.
    show_welcome: bool = False;

    compact_layout: bool = (
        total == 0
        and (not is_streaming)
        and auth_kind == "idle"
        and (not has_dialog)
    );

    prompt_props: dict = {
        "prompt_marker": prompt_marker,
        "input_reset_key": input_reset_key,
        "input_text": input_text,
        "input_cursor": input_cursor,
        "show_completions": show_completions,
        "completions_list": completions_list,
        "completion_selection": completion_selection,
    };

    return (
        <Box flexDirection="column" padding={0}>
            <StatusBar
                phase={phase}
                mode={dev_mode}
                model={model_id}
                provider={provider_id}
                session_name={session_name}
                msg_count={total}
                tools_running={len(running_tools)}
                mcp_connected={bool(getattr(snap, "mcpConnected", False))}
                mcp_connecting={bool(getattr(snap, "mcpConnecting", False))}
                mcp_tools={int(getattr(snap, "mcpToolCount", 0))}
                usage_line={usage_line}
            />
            {pending_approval and <ApprovalBanner pending={pending_approval}/>}
            <Text color="gray">{divider}</Text>
            {show_help and <HelpPanel/>}
            {compact_layout and <PromptBar {...prompt_props}/>}
            {(not compact_layout) and (
                <Box key={"chat-" + str(transcript_epoch)}>
                    <ChatHistory
                        start_chat={True}
                        messages={msgs_list}
                        model={model_id}
                        live_component={live_component}
                    />
                </Box>
            )}
            {(not compact_layout) and len(tools_list) > 0 and (
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
            {ui.workingVisible and ui.workingMessage and (
                <Box paddingX={1}>
                    <Text color="cyan">{"(working) "}</Text>
                    <Text color="cyan">{to_str(ui.workingMessage)}</Text>
                </Box>
            )}
            {(not compact_layout) and <PromptBar {...prompt_props}/>}
        </Box>
    );
}
