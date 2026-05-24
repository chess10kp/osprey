"""TUI test entry — single jac tui compile unit for vitest (not shipped in jackal.sh)."""

import from "ink" { Box, Text }
import from "./components/welcomemsg.cl.jac" { WelcomeMessage }
import from "./components/statusbar.cl.jac" { StatusBar }
import from "./components/streammsg.cl.jac" { StreamingMessage }
import from "./components/transcript.cl.jac" { ChatHistory, ChatQueue, TranscriptRow }
import from "./components/authflow.cl.jac" {
    ProviderPicker,
    BrowserAuthView,
    AuthPromptView,
    ModelPicker,
    AuthErrorView,
}
import from "./components/helppanel.cl.jac" { HelpPanel }
import from "./components/toolline.cl.jac" { ToolRow, ToolTimeline }
import from "./components/userinput.cl.jac" { UserInput, CompletionList }


def:pub app() -> JsxElement {
    return (
        <Box>
            <Text>TUI test fixture</Text>
        </Box>
    );
}
