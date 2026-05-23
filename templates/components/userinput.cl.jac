"""UserInput -- the main prompt input area with completions.
Ported from nanocoder's UserInput component."""

import from "ink" { Box, Text, useInput }
import from "@inkjs/ui" { TextInput }


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
