"""Jac-native word-boundary navigation for the ported pi-tui editor/input.

The js2jac conversion left JS idioms in place: word iteration via
`segments[Symbol.iterator]()`, `String.matchAll(RegExp(PUNCTUATION, "g"))`,
and `RegExp.exec`. Node/stdlib `re` supports none of that surface. This
module reimplements findWordBackward / findWordForward against the
Jac-native WordSegmenter (utils.getWordSegmenter, backed by unicode_support)
and the stdlib `re` PUNCTUATION_REGEX, walking plain lists of segments.

A segment is either a unicode_support.Seg object (the default segmenter
path, carrying `.segment` / `.index` / `.isWordLike`) or a dict
{"segment", "index", ...} produced by a custom `segmentFn` (the editor's
paste-marker segmenter). Both carry a `segment` string; only Seg objects
carry `isWordLike`. The accessors below read either shape.

`options` (optional) mirrors the JS options bag as a dict:
  - "segment":         fn(text) -> list[segment]   custom segmenter
  - "isAtomicSegment": fn(str)  -> bool            treat a segment as indivisible
When omitted (input.jac path) the default WordSegmenter is used and no
segment is atomic.
"""

import from re { finditer, search }
import from .utils { getWordSegmenter, isWhitespaceChar, PUNCTUATION_REGEX }

glob wordSegmenter = getWordSegmenter();

def _segStr(seg: any) -> str {
    if isinstance(seg, dict) {
        return ((seg["segment"] if ("segment" in seg) else "") as str);
    }
    return (seg.segment as str);
}

def _segIsWordLike(seg: any) -> bool {
    if isinstance(seg, dict) {
        return (bool(seg["isWordLike"]) if ("isWordLike" in seg) else False);
    }
    return bool(seg.isWordLike);
}

def _optFn(options: any, key: str) -> any {
    if ((options is not None) and (key in options)) {
        return options[key];
    }
    return None;
}

def _atomic(isAtomic: any, s: str) -> bool {
    if (isAtomic is None) {
        return False;
    }
    return bool(isAtomic(s));
}

def:pub findWordBackward(text: str, cursor: float, options: any = None) -> float {
    c = int(cursor);
    if (c <= 0) {
        return 0.0;
    }
    textBeforeCursor = text[0:c];
    segmentFn = _optFn(options, "segment");
    isAtomic = _optFn(options, "isAtomicSegment");
    raw = (segmentFn(textBeforeCursor) if (segmentFn is not None) else wordSegmenter.segment(textBeforeCursor));
    segments = list(raw);
    newCursor = c;
    # Skip trailing whitespace segments.
    while (len(segments) > 0) {
        s = _segStr(segments[(len(segments) - 1)]);
        if (_atomic(isAtomic, s) or not isWhitespaceChar(s)) {
            break;
        }
        popped = segments.pop();
        newCursor -= len(_segStr(popped));
    }
    if (len(segments) == 0) {
        return float(newCursor);
    }
    last = segments[(len(segments) - 1)];
    lastStr = _segStr(last);
    if _atomic(isAtomic, lastStr) {
        newCursor -= len(lastStr);
    }
    elif _segIsWordLike(last) {
        matches = list(finditer(PUNCTUATION_REGEX, lastStr));
        if (len(matches) <= 0) {
            newCursor -= len(lastStr);
        }
        else {
            lastMatch = matches[(len(matches) - 1)];
            newCursor -= (len(lastStr) - (lastMatch.start() + len(lastMatch.group(0))));
        }
    }
    else {
        # Consume a run of punctuation segments.
        while (len(segments) > 0) {
            item = segments[(len(segments) - 1)];
            s = _segStr(item);
            if ((_atomic(isAtomic, s) or _segIsWordLike(item)) or isWhitespaceChar(s)) {
                break;
            }
            popped = segments.pop();
            newCursor -= len(_segStr(popped));
        }
    }
    return float(newCursor);
}

def:pub findWordForward(text: str, cursor: float, options: any = None) -> float {
    c = int(cursor);
    if (c >= len(text)) {
        return float(len(text));
    }
    textAfterCursor = text[c:];
    segmentFn = _optFn(options, "segment");
    isAtomic = _optFn(options, "isAtomicSegment");
    raw = (segmentFn(textAfterCursor) if (segmentFn is not None) else wordSegmenter.segment(textAfterCursor));
    segments = list(raw);
    newCursor = c;
    i = 0;
    n = len(segments);
    # Skip leading whitespace segments.
    while (i < n) {
        s = _segStr(segments[i]);
        if (_atomic(isAtomic, s) or not isWhitespaceChar(s)) {
            break;
        }
        newCursor += len(s);
        i += 1;
    }
    if (i >= n) {
        return float(newCursor);
    }
    cur = segments[i];
    curStr = _segStr(cur);
    if _atomic(isAtomic, curStr) {
        newCursor += len(curStr);
    }
    elif _segIsWordLike(cur) {
        m = search(PUNCTUATION_REGEX, curStr);
        newCursor += (m.start() if (m is not None) else len(curStr));
    }
    else {
        # Consume a run of punctuation segments.
        while (i < n) {
            item = segments[i];
            s = _segStr(item);
            if ((_atomic(isAtomic, s) or _segIsWordLike(item)) or isWhitespaceChar(s)) {
                break;
            }
            newCursor += len(s);
            i += 1;
        }
    }
    return float(newCursor);
}
