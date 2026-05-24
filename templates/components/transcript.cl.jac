"""Transcript UI — Static queue, row renderer, and chat history (single module)."""

import from "ink" { Box, Static, Text }
import from .usermsg { UserMessage }
import from .asstmsg { AssistantMessage }
import from .toolline { ToolMessage }


def estimate_tokens(text: str) -> int {
    if not text { return 0; }
    return int(len(text) / 4);
}


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


def entry_kind(row: any) -> str {
    if hasattr(row, "kind") {
        kind_val: any = row.kind;
        if kind_val is not None { return str(kind_val); }
    }
    if hasattr(row, "keys") and "kind" in row {
        return str(row["kind"]);
    }
    return msg_role(row);
}


def entry_field(row: any, key: str) -> any {
    if hasattr(row, key) {
        return getattr(row, key, None);
    }
    if hasattr(row, "keys") and key in row {
        return row[key];
    }
    return None;
}


def normalize_transcript(props: any) -> list {
    raw: any = props.transcript if props.transcript else None;
    if raw is not None {
        items: list = list(raw);
        if len(items) > 0 { return items; }
    }
    messages: list = list(props.messages) if props.messages else [];
    normalized: list = [];
    for m in messages {
        role: str = msg_role(m);
        normalized.append({"kind": role, "text": safe_text(m)});
    }
    return normalized;
}


def:pub LiveToolRow(props: any) -> JsxElement {
    row: any = props.row;
    compact: bool = bool(props.compact) if props.compact is not None else False;
    tool_name: str = str(entry_field(row, "toolName")) if entry_field(row, "toolName") else "unknown";
    status: str = str(entry_field(row, "status")) if entry_field(row, "status") else "running";
    return (
        <ToolMessage
            tool_name={tool_name}
            status={status}
            input={entry_field(row, "input")}
            result={entry_field(row, "result")}
            duration_ms={entry_field(row, "durationMs")}
            compact={compact}
        />
    );
}


def:pub TranscriptRow(props: any) -> JsxElement {
    row: any = props.msg;
    model: str = str(props.model) if props.model else "";
    compact: bool = bool(props.compact) if props.compact is not None else False;
    kind: str = entry_kind(row);

    if kind == "user" {
        return <UserMessage message={safe_text(row)} tokens={estimate_tokens(safe_text(row))}/>;
    }
    if kind == "assistant" {
        return <AssistantMessage message={safe_text(row)} model={model}/>;
    }
    if kind == "tool" {
        tool_name: str = str(entry_field(row, "toolName")) if entry_field(row, "toolName") else "unknown";
        status: str = str(entry_field(row, "status")) if entry_field(row, "status") else "done";
        return (
            <ToolMessage
                tool_name={tool_name}
                status={status}
                input={entry_field(row, "input")}
                result={entry_field(row, "result")}
                duration_ms={entry_field(row, "durationMs")}
                compact={compact}
            />
        );
    }
    if kind == "system" {
        return (
            <Box flexDirection="column" paddingX={1} marginBottom={1}>
                <Text dimColor>{"[system] " + safe_text(row)}</Text>
            </Box>
        );
    }
    return (
        <Box flexDirection="column" paddingX={1} marginBottom={1}>
            <Text dimColor>{"[" + kind + "] " + safe_text(row)}</Text>
        </Box>
    );
}


def build_transcript_rows(transcript: list, model: str, compact: bool) -> list {
    rows: list = [];
    for i in range(len(transcript)) {
        row: any = transcript[i];
        kind: str = entry_kind(row);
        if kind == "tool" {
            status: str = str(entry_field(row, "status")) if entry_field(row, "status") else "done";
            if status == "running" { continue; }
        }
        rows.append(
            <TranscriptRow key={"row-" + str(i)} msg={row} model={model} compact={compact}/>
        );
    }
    return rows;
}


def render_static_row(row: any, _index: int) -> any {
    return row;
}


def:pub ChatQueue(props: any) -> JsxElement {
    transcript: list = normalize_transcript(props);
    model: str = str(props.model) if props.model else "";
    compact: bool = bool(props.compact) if props.compact is not None else False;
    rows: list = build_transcript_rows(transcript, model, compact);

    if len(rows) == 0 {
        return <Box flexDirection="column"></Box>;
    }

    return (
        <Box flexDirection="column">
            <Static items={rows}>{render_static_row}</Static>
        </Box>
    );
}


def:pub ChatHistory(props: any) -> JsxElement {
    model: str = str(props.model) if props.model else "";
    compact: bool = bool(props.compact) if props.compact is not None else False;
    live: any = props.live_component;
    live_tool: any = props.live_tool_component;

    return (
        <Box flexDirection="column" flexGrow={1}>
            <ChatQueue transcript={normalize_transcript(props)} model={model} compact={compact}/>
            {live_tool and (
                <Box flexDirection="column">
                    {live_tool}
                </Box>
            )}
            {live and (
                <Box flexDirection="column" paddingX={1}>
                    {live}
                </Box>
            )}
        </Box>
    );
}
