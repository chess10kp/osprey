"""AssistantMessage — finalized assistant response with markdown rendering.
Renders headings, bold, italic, lists, blockquotes, links, inline code,
and syntax-highlighted fenced code blocks using the markdown parser utility.
Code blocks render without the left border for clean terminal copy/paste.
Ported from nanocoder's AssistantMessage."""

import from "ink" { Box, Text }
import from .theme { SECONDARY, INFO, TEXT, PRIMARY, TOOL }
import from "../markdown.mjs" { parseMarkdownParts }


def render_content_blocks(display: str) -> list {
    colors: dict = {
        "primary": PRIMARY,
        "secondary": SECONDARY,
        "info": INFO,
        "text": TEXT,
        "tool": TOOL,
    };
    parts: list = parseMarkdownParts(display, colors, 80);

    has_parts: bool = len(parts) > 0;
    single_empty: bool = len(parts) == 1 and not str(parts[0]["content"]).strip();

    if not has_parts or single_empty {
        return [
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
                borderLeftColor={SECONDARY}
            >
                <Text>{display}</Text>
            </Box>
        ];
    }

    rendered_parts: list = [];
    for i in range(len(parts)) {
        part: any = parts[i];
        ptype: str = str(part["type"]) if "type" in part else "text";
        pcontent: str = str(part["content"]) if "content" in part else "";
        if not pcontent.strip() { continue; }

        if ptype == "code" {
            rendered_parts.append(
                <Box key={i} flexDirection="column" marginBottom={1}>
                    <Text>{pcontent}</Text>
                </Box>
            );
        } else {
            rendered_parts.append(
                <Box
                    key={i}
                    flexDirection="column"
                    marginBottom={1}
                    backgroundColor="#1a1a2e"
                    padding={1}
                    borderStyle="bold"
                    borderLeft={true}
                    borderRight={false}
                    borderTop={false}
                    borderBottom={false}
                    borderLeftColor={SECONDARY}
                >
                    <Text>{pcontent}</Text>
                </Box>
            );
        }
    }
    return rendered_parts;
}


def:pub AssistantMessage(props: any) -> JsxElement {
    message: str = str(props.message) if props.message else "";
    model: str = str(props.model) if props.model else "";
    display: str = message.strip() if message else "";
    rendered_parts: list = render_content_blocks(display);

    return (
        <Box flexDirection="column">
            <Box marginBottom={1} marginTop={1}>
                <Text color={INFO} bold>{(model if model else "Assistant") + ":"}</Text>
            </Box>
            {rendered_parts}
        </Box>
    );
}
