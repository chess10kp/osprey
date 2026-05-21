"""Jackal TUI Shell — Ink-based coding agent TUI.

Self-contained shell that boots a Pi AgentSession, renders messages,
streaming text, tool calls, and runs a full prompt loop.
Compile with: jac jac2ink shell.cl.jac --with_pi
"""

import from "@jac/runtime" { JsxElement }

# ──── Helper ──────────────────────────────────────────────────────────────
def truncate(s: str, max_len: int = 120) -> str {
    if not s {
        return "";
    }
    flat: str = s.replace("\n", "↵");
    if len(flat) > max_len {
        return flat[:max_len] + "…";
    }
    return flat;
}

# ──── Header ──────────────────────────────────────────────────────────────
def:pub Header(phase: str, provider: str, model: str) -> JsxElement {
    phase_color: str = "green"
        if phase == "streaming"
        else (
            "red"
                if phase == "error"
                else (
                    "yellow"
                        if phase == "compacting"
                        else ("magenta" if phase == "retrying" else "cyan")
                )
        );
    model_label: str = f"{provider}/{model}" if model else "no model";

    return
        <box flexDirection="row" justifyContent="space-between" paddingX={1}>
            <text bold={true} color="magenta">{"🐺 Jackal"}</text>
            <text color={phase_color}>{phase}</text>
            <text dimColor={true}>{model_label}</text>
        </box>;
}

# ──── ToolCall ────────────────────────────────────────────────────────────
def:pub ToolCall(
    tool_id: str, name: str, status: str, input_json: str, result_text: str
) -> JsxElement {
    icon: str = "⏳" if status == "running" else "✓";
    color: str = "yellow" if status == "running" else "green";
    input_preview: str = truncate(input_json, 80) if input_json else "";
    result_preview: str = truncate(result_text, 100) if result_text else "";

    return
        <box flexDirection="column" marginLeft={2} marginY={0}>
            <text>
                <text color={color}>{icon + " "}</text>
                <text bold={true}>{name}</text>
                {<text dimColor={true}>{" " + input_preview}</text>
                    if input_preview
                    else <text/>}
            </text>
            {<box marginLeft={2}>
                <text dimColor={true} color="gray">{"→ " + result_preview}</text>
            </box>
                if result_preview
                else <text/>}
        </box>;
}

# ──── StatusBar ───────────────────────────────────────────────────────────
def:pub StatusBar(
    phase: str, error: str, tool_count: int, running_count: int
) -> JsxElement {
    parts: list[str] = [];
    if phase == "streaming" {
        parts.append("⏳ streaming");
    }
    if phase == "compacting" {
        parts.append("🗑 compacting");
    }
    if phase == "retrying" {
        parts.append("🔄 retrying");
    }
    if error {
        parts.append("❌ " + error);
    }
    if tool_count > 0 {
        detail: str = f" ({running_count} running)" if running_count > 0 else "";
        parts.append(f"🔧 {tool_count} tools{detail}");
    }
    if len(parts) == 0 {
        parts.append("ready");
    }
    parts.append("Esc=abort");

    return
        <box
            borderStyle="single"
            borderColor="gray"
            paddingX={1}
            justifyContent="space-between"
        >
            <text dimColor={true}>{" │ ".join(parts[:-1])}</text>
            <text dimColor={true} color="gray">{parts[-1]}</text>
        </box>;
}

# ──── HelpOverlay ─────────────────────────────────────────────────────────
def:pub HelpOverlay() -> JsxElement {
    return
        <box
            flexDirection="column"
            borderStyle="round"
            borderColor="yellow"
            paddingX={1}
        >
            <text bold={true} color="yellow">{"Commands:"}</text>
            <text>{"  /help        Show this help"}</text>
            <text>{"  /model       Show current model"}</text>
            <text>{"  /clear       Clear messages"}</text>
            <text>{"  /tools       Show tool execution log"}</text>
            <text>{"  /exit, /quit Exit Jackal"}</text>
            <text>{"  Esc          Abort streaming"}</text>
        </box>;
}

# ──── MessageLine ─────────────────────────────────────────────────────────
def:pub MessageLine(role: str, text: str) -> JsxElement {
    prefix: str = "> " if role == "user" else "";
    color: str = "cyan" if role == "user" else "white";
    return
        <text color={color}>{prefix + text}</text>;
}

# ──── StreamLine ──────────────────────────────────────────────────────────
def:pub StreamLine(text: str) -> JsxElement {
    return
        <text color="green">{text}</text>;
}

# ──── Separator ───────────────────────────────────────────────────────────
def:pub Separator(width: int = 60) -> JsxElement {
    return
        <text color="gray">{"─" * width}</text>;
}

# ──── Prompt ──────────────────────────────────────────────────────────────
def:pub Prompt(input_text: str) -> JsxElement {
    return
        <box marginTop={0}>
            <text color="green" bold={true}>{"❯ "}</text>
            <text>{input_text}</text>
            <text dimColor={true}>{"█"}</text>
        </box>;
}
