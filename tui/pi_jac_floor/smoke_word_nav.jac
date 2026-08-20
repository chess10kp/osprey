"""Runtime smoke for word_navigation (findWordBackward / findWordForward).

Drives the Jac-native word-motion port under the runtime: default
WordSegmenter path (input.jac usage) plus the custom segmentFn / atomic
options bag (editor.jac usage), including dict-shaped segments.

Run: jac run smoke_word_nav.jac
"""

import from src.word_navigation { findWordBackward, findWordForward }

with entry {
    # --- default segmenter path (no options) ---

    # forward from a word start lands at end of the word, before the space.
    assert findWordForward("hello world", 0.0) == 5.0;
    # forward across the space lands at end of the next word.
    assert findWordForward("hello world", 5.0) == 11.0;
    # already at end-of-text: clamp.
    assert findWordForward("hello world", 11.0) == 11.0;

    # backward from end-of-text lands at start of the last word.
    assert findWordBackward("hello world", 11.0) == 6.0;
    # backward across the space lands at start of the first word.
    assert findWordBackward("hello world", 6.0) == 0.0;
    # already at column 0: clamp.
    assert findWordBackward("hello world", 0.0) == 0.0;

    # --- punctuation boundaries ("foo.bar") ---

    # forward stops before punctuation, then consumes the punctuation run.
    assert findWordForward("foo.bar", 0.0) == 3.0;
    assert findWordForward("foo.bar", 3.0) == 4.0;
    # backward mirrors: start of last word, then across the punctuation.
    assert findWordBackward("foo.bar", 7.0) == 4.0;
    assert findWordBackward("foo.bar", 4.0) == 3.0;

    # --- custom options bag: dict segments + isAtomicSegment ---

    isAtomicX = lambda (s: any) -> bool { return (s == "[X]"); };

    # an atomic segment is consumed whole even though it is punctuation.
    segAtomicFirst = lambda (t: any) -> any {
        return [{"segment": "[X]"}, {"segment": "cd", "isWordLike": True}];
    };
    optsA = {"segment": segAtomicFirst, "isAtomicSegment": isAtomicX};
    assert findWordForward("[X]cd", 0.0, optsA) == 3.0;

    # a word-like dict segment stops before the following atomic marker.
    segWordFirst = lambda (t: any) -> any {
        return [{"segment": "ab", "isWordLike": True}, {"segment": "[X]"}];
    };
    optsB = {"segment": segWordFirst, "isAtomicSegment": isAtomicX};
    assert findWordForward("ab[X]", 0.0, optsB) == 2.0;

    print("smoke_word_nav: OK");
}
