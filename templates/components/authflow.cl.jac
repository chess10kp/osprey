"""AuthFlow — provider picker, browser auth, API key input, model picker overlays.
Ported from nanocoder's modal selector patterns."""

import from "ink" { Box, Text }
import from .theme { PRIMARY, SECONDARY, INFO, WARNING, ERROR, ACCENT, SUCCESS }


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
            borderColor={INFO}
            paddingX={2}
            paddingY={1}
            marginTop={1}
        >
            <Text bold color={INFO}>{"Select a provider"}</Text>
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
            borderColor={ACCENT}
            paddingX={2}
            paddingY={1}
            marginTop={1}
        >
            <Text bold color={ACCENT}>{"Browser authentication"}</Text>
            <Text>{"Open in browser:"}</Text>
            <Text color={INFO}>{url}</Text>
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
            borderColor={WARNING}
            paddingX={2}
            paddingY={1}
            marginTop={1}
        >
            <Text bold color={WARNING}>{msg}</Text>
            <Box>
                <Text color={SUCCESS}>{"> "}</Text>
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

    return (
        <Box
            flexDirection="column"
            borderStyle="round"
            borderColor={INFO}
            paddingX={2}
            paddingY={1}
            marginTop={1}
        >
            <Text bold color={INFO}>{"Select a model"}</Text>
            <Text dimColor>{"Type 'provider/model' and Enter. Esc to cancel."}</Text>
            {len(filtered) > 0 and <Text dimColor>{str(len(filtered)) + " models available (shown in completions below)."}</Text>}
        </Box>
    );
}


def:pub AuthErrorView(message: str) -> JsxElement {
    return (
        <Box
            flexDirection="column"
            borderStyle="round"
            borderColor={ERROR}
            paddingX={2}
            paddingY={1}
            marginTop={1}
        >
            <Text bold color={ERROR}>{"Auth error"}</Text>
            <Text>{message}</Text>
            <Text dimColor>{"Esc to dismiss. /login to retry."}</Text>
        </Box>
    );
}
