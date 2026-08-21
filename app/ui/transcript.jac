"""Transcript projection, streaming, and virtualization (OSPUI.md §16).

Messages stay in domain state. TranscriptView binds source_id + revision;
the renderer materializes visible wrapped lines + overscan only. Measurement
cache key: (message_id, width, content_rev, style_rev).
"""

import from ui.model {
    TranscriptView,
    node_id,
}


obj TranscriptMessage {
    has message_id: str,
        content: str = "",
        content_rev: int = 0,
        style_rev: int = 0;
}


obj MeasureCache {
    has entries: dict[str, int] = {};
}


obj VisibleWindow {
    has lines: list[str] = [],
        first_message_id: str = "",
        last_message_id: str = "",
        anchor_message_id: str = "",
        anchor_offset: int = 0,
        cells_would_damage: bool = False;
}


obj TranscriptProjection {
    has view: TranscriptView,
        measure_cache: MeasureCache,
        messages: list[TranscriptMessage] = [],
        overscan: int = 2,
        viewport_height: int = 10,
        viewport_width: int = 40;
}


def create_measure_cache() -> MeasureCache {
    return MeasureCache();
}


def measure_cache_key(
    message_id: str,
    width: int,
    content_rev: int,
    style_rev: int,
) -> str {
    return (
        message_id
        + "|"
        + str(width)
        + "|"
        + str(content_rev)
        + "|"
        + str(style_rev)
    );
}


"""Bind a TranscriptView to a domain source and empty projection.

Unit 10 implementation fills this in. Stub raises until then.
"""
def bind_transcript(
    view: TranscriptView,
    source_id: str,
    width: int = 40,
    height: int = 10,
) -> TranscriptProjection {
    _ = (view, source_id, width, height);
    raise NotImplementedError("Unit 10: bind_transcript");
}


"""Replace projection messages for a new observed revision.

Unit 10 implementation fills this in. Stub raises until then.
"""
def apply_transcript_revision(
    proj: TranscriptProjection,
    revision: int,
    messages: list[TranscriptMessage],
) {
    _ = (proj, revision, messages);
    raise NotImplementedError("Unit 10: apply_transcript_revision");
}


"""Return wrapped line height for one message, using the measurement cache.

Unit 10 implementation fills this in. Stub raises until then.
"""
def measure_message_height(
    proj: TranscriptProjection,
    message: TranscriptMessage,
    width: int,
) -> int {
    _ = (proj, message, width);
    raise NotImplementedError("Unit 10: measure_message_height");
}


"""Materialize visible + overscan lines for the current scroll window.

Unit 10 implementation fills this in. Stub raises until then.
"""
def materialize_visible(proj: TranscriptProjection) -> VisibleWindow {
    _ = proj;
    raise NotImplementedError("Unit 10: materialize_visible");
}


"""True if a revision change requires terminal damage for this viewport.

Off-screen changes must return False unless anchor/scroll range changes
(OSPUI.md §16). Unit 10 implementation fills this in.
"""
def transcript_needs_damage(
    proj: TranscriptProjection,
    prev_revision: int,
    next_revision: int,
) -> bool {
    _ = (proj, prev_revision, next_revision);
    raise NotImplementedError("Unit 10: transcript_needs_damage");
}


"""Set follow_tail and optionally pin scroll to newest content.

Unit 10 implementation fills this in. Stub raises until then.
"""
def set_follow_tail(proj: TranscriptProjection, follow: bool) {
    _ = (proj, follow);
    raise NotImplementedError("Unit 10: set_follow_tail");
}
