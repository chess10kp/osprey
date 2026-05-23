"""ChatQueue — frozen transcript via Ink Static (append-only)."""

import from "ink" { Box, Static }
import from .transcriptrow { TranscriptRow }


def build_transcript_rows(messages: list, model: str) -> list {
    rows: list = [];
    for msg in messages {
        rows.append(<TranscriptRow msg={msg} model={model}/>);
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
