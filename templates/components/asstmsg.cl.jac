"""AssistantMessage — finalized assistant response with markdown rendering.
Renders headings, bold, italic, lists, blockquotes, links, inline code,
and syntax-highlighted fenced code blocks using the markdown parser utility.
Code blocks render without the left border for clean terminal copy/paste.
Ported from nanocoder's AssistantMessage."""

import from "ink" { Box, Text }
import from .theme { SECONDARY, INFO, TEXT, PRIMARY, TOOL }
import from "../markdown.mjs" { parseMarkdownParts }


def asst_estimate_tokens(text: str) -> int {
    if not text { return 0; }
    return int(len(text) / 4);
}


def:pub AssistantMessage(props: any) -> JsxElement {
    message: str = str(props.message) if props.message else "";
    model: str = str(props.model) if props.model else "";
    tokens: int = asst_estimate_tokens(message);
    display: str = message.strip() if message else "";

    colors: dict = {
        "primary": PRIMARY,
        "secondary": SECONDARY,
        "info": INFO,
        "text": TEXT,
        "tool": TOOL,
    };
    parts: list = parseMarkdownParts(display, colors, 80);

    # Fallback: if parsing returned nothing useful, render plain text
    has_parts: bool = len(parts) > 0;
    single_empty: bool = len(parts) == 1 and not str(parts[0].get("content", "")).strip();

    if not has_parts or single_empty {
        return (
            <Box flexDirection="column">
                <Box marginBottom={1} marginTop={1}>
                    <Text color={INFO} bold>{(model if model else "Assistant") + ":"}</Text>
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
                    borderLeftColor={SECONDARY}
                >
                    <Text>{display}</Text>
                </Box>
                <Box marginBottom={1}>
                    <Text color={SECONDARY}>{"~" + str(tokens) + " tokens"}</Text>
                </Box>
            </Box>
        );
    }

    # Render each markdown part: text in bordered box, code without border
    rendered_parts: list = [];
    for (i, p) in enumerate(parts) {
        ptype: str = str(p.get("type", "text"));
        pcontent: str = str(p.get("content", ""));
        if not pcontent.strip() { continue; }

        if ptype == "code" {
            # Code blocks: no border, clean copy/paste
            rendered_parts.append(
                <Box key={i} flexDirection="column" marginBottom={1}>
                    <Text>{pcontent}</Text>
                </Box>
            );
        } else {
            # Text parts: bordered box
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

    return (
        <Box flexDirection="column">
            <Box marginBottom={1} marginTop={1}>
                <Text color={INFO} bold>{(model if model else "Assistant") + ":"}</Text>
            </Box>
            {rendered_parts}
            <Box marginBottom={1}>
                <Text color={SECONDARY}>{"~" + str(tokens) + " tokens"}</Text>
            </Box>
        </Box>
    );
}
