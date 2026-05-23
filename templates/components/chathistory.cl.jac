"""ChatHistory — Static transcript + live streaming region (never unmount mid-session)."""

import from "ink" { Box }
import from .chatqueue { ChatQueue }


def:pub ChatHistory(props: any) -> JsxElement {
    messages: any = props.messages;
    model: any = props.model;
    live: any = props.live_component;
    start_chat: bool = True;
    if props.start_chat is not None {
        start_chat = bool(props.start_chat);
    }

    return (
        <Box flexDirection="column" flexGrow={1}>
            {start_chat and (
                <ChatQueue messages={messages} model={model}/>
            )}
            {live and (
                <Box flexDirection="column" paddingX={1}>
                    {live}
                </Box>
            )}
        </Box>
    );
}
