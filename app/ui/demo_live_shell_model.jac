"""State model shared by the live shell facade and its helper modules."""

import from ui.runtime { UiSession }
import from ui.screen { ShellScreen }
import from ui.transcript { TranscriptMessage, TranscriptProjection }
import from ui.renderer { Renderer }
import from ui.terminal { ProcessTerminal }
import from ui.input { InputNormalizer }
import from ui.progress_bar { ProgressBar }


obj LiveShell {
    has session: UiSession,
        shell: ShellScreen,
        proj: TranscriptProjection,
        renderer: Renderer,
        term: ProcessTerminal,
        normalizer: InputNormalizer,
        progress: ProgressBar,
        messages: list[TranscriptMessage] = [],
        rev: int = 0,
        msg_n: int = 0,
        phase: str = "ready",
        progress_value: float = 0.0,
        stream_full: str = "",
        stream_shown: int = 0,
        stream_msg_id: str = "",
        stream_tick: int = 0,
        spin_i: int = 0,
        running: bool = True,
        dirty: bool = True,
        columns: int = 80,
        rows: int = 24,
        status_hint: str = "enter · ↑↓ history · esc quit";
}
