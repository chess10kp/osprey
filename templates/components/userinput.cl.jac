"""UserInput -- the main prompt input area with completions.
Ported from nanocoder's UserInput component."""

import from "ink" { Box, Text, useInput }
import from "@inkjs/ui" { TextInput }


def:pub CompletionList(items: list, selected_index: int) -> JsxElement {
    sel_idx: int = selected_index;
    shown: list = items[:8];
    rows: list = [];
    # range loop — jac2ink breaks enumerate when sel_idx is compared in the body
    for i in range(len(shown)) {
        f = shown[i];
        is_sel: bool = i == sel_idx;
        icon: str = "▸ " if is_sel else "  ";
        rows.append(
            <Text color="cyan" bold={is_sel}>{icon + str(f)}</Text>
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
                borderTop={true}
                borderBottom={false}
                borderLeft={false}
                borderRight={false}
                borderTopColor={ "blue" if is_bash else "magenta" }
            >
                <Box>
                    {len(input_text) == 0 and <Text color="gray">{"> "}</Text>}
                    <TextInput
                        defaultValue={input_text}
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
