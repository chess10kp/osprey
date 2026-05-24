"""Transcript UI — Static queue, row renderer, and chat history (single module)."""

import from "ink" { Box, Static, Text }
import from .usermsg { UserMessage }
import from .asstmsg { AssistantMessage }


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


def:pub TranscriptRow(props: any) -> JsxElement {
    msg: any = props.msg;
    model: str = str(props.model) if props.model else "";
    role: str = msg_role(msg);
    text: str = safe_text(msg);

    if role == "user" {
        return <UserMessage message={text} tokens={estimate_tokens(text)}/>;
    }
    if role == "assistant" {
        return <AssistantMessage message={text} model={model}/>;
    }
    return (
        <Box flexDirection="column" paddingX={1} marginBottom={1}>
            <Text dimColor>{"[" + role + "] " + text}</Text>
        </Box>
    );
}


def build_transcript_rows(messages: list, model: str) -> list {
    rows: list = [];
    for (i, f) in enumerate(messages) {
        rows.append(<TranscriptRow key={"row-" + str(i)} msg={f} model={model}/>);
    }
    return rows;
}


def render_static_row(row: any, _index: int) -> any {
    return row;
}


def:pub ChatQueue(props: any) -> JsxElement {
    messages: list = list(props.messages) if props.messages else [];
    model: str = str(props.model) if props.model else "";
    rows: list = build_transcript_rows(messages, model);

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
    messages: any = props.messages;
    model: any = props.model;
    live: any = props.live_component;

    return (
        <Box flexDirection="column" flexGrow={1}>
            <ChatQueue messages={messages} model={model}/>
            {live and (
                <Box flexDirection="column" paddingX={1}>
                    {live}
                </Box>
            )}
        </Box>
    );
}
