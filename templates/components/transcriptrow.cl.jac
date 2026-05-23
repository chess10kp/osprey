"""TranscriptRow — render one finalized store message for Static transcript."""

import from "ink" { Box, Text }
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
