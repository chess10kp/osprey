"""Runtime smoke for the editor word-motion wiring.

Exercises editor.segmentWithMarkers (the paste-marker segmenter that
feeds the editor's custom `segment` lambda) and drives findWordForward /
findWordBackward through it with isPasteMarker as the atomic guard --
the exact options bag editor.jac passes for word-motion.

The original js2jac output left JS idioms in segmentWithMarkers
(`validIds.size`, `text.matchAll`, `validIds.has`, match-object `m[0]`/
`m[1]`/`m.index`, and attr-access on the `{start,end}` marker dicts).
This confirms the Jac-native rewrite runs under the runtime.

Run: jac run smoke_editor_wordmotion.jac
"""

import from src.components.editor { isPasteMarker, segmentWithMarkers }
import from src.utils { getWordSegmenter }
import from src.word_navigation { findWordBackward, findWordForward }

with entry {
    ws = getWordSegmenter();

    # --- segmentWithMarkers: empty validIds -> plain segmenter passthrough ---
    plain = list(segmentWithMarkers("hi yo", ws, set()));
    assert (plain[0].segment == "hi");

    # --- segmentWithMarkers: a valid paste marker becomes one atomic Seg ---
    # (segmentWithMarkers returns a uniform list[Seg]; the marker branch now
    #  builds a Seg, matching the base segmenter instead of a bare dict.)
    text = "hi [paste #1 3 chars] yo";
    marker = "[paste #1 3 chars]";
    assert isPasteMarker(marker);
    # marker spans text[3:21]
    assert (text[3:21] == marker);

    segs = list(segmentWithMarkers(text, ws, {1}));
    markerSegs = [s for s in segs if (s.segment == marker)];
    assert (len(markerSegs) == 1);
    assert (markerSegs[0].index == 3);

    # an invalid id (not in validIds) is NOT collapsed into a marker segment.
    segs2 = list(segmentWithMarkers(text, ws, {7}));
    markerSegs2 = [s for s in segs2 if (s.segment == marker)];
    assert (len(markerSegs2) == 0);

    # --- full word-motion wiring: marker treated as an atomic unit ---
    segFn = lambda (t: any) -> any { return segmentWithMarkers(t, ws, {1}); };
    opts = {"segment": segFn, "isAtomicSegment": isPasteMarker};

    # forward from the marker start jumps the whole marker (3 -> 21).
    assert (findWordForward(text, 3.0, opts) == 21.0);
    # backward from the marker end jumps back over the whole marker (21 -> 3).
    assert (findWordBackward(text, 21.0, opts) == 3.0);

    print("smoke_editor_wordmotion: OK");
}
