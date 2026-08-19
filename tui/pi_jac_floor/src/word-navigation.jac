import from "./utils.jac" { getWordSegmenter, isWhitespaceChar, PUNCTUATION_REGEX }

glob wordSegmenter = getWordSegmenter();

def:pub findWordBackward(text: str, cursor: float, options: any) -> float {
    if (cursor <= 0) {
        return 0;
    }
    textBeforeCursor = text[0:cursor];
    segmentFn = ((lambda (_jx_opt0: any) -> any { return (_jx_opt0.segment if _jx_opt0 is not None else None); })(options));
    isAtomic = ((lambda (_jx_opt1: any) -> any { return (_jx_opt1.isAtomicSegment if _jx_opt1 is not None else None); })(options));
    segments = ([*segmentFn(textBeforeCursor)] if segmentFn else [*wordSegmenter.segment(textBeforeCursor)]);
    newCursor = cursor;
    while (((len(segments) > 0) and not ((lambda (_jx_opt2: any) -> any { return (_jx_opt2((((lambda (_jx_opt3: any) -> any { return (_jx_opt3.segment if _jx_opt3 is not None else None); })(segments[(len(segments) - 1)])) or "")) if _jx_opt2 is not None else None); })(isAtomic))) and isWhitespaceChar((((lambda (_jx_opt4: any) -> any { return (_jx_opt4.segment if _jx_opt4 is not None else None); })(segments[(len(segments) - 1)])) or ""))) {
        newCursor -= (((lambda (_jx_opt5: any) -> any { return (len(_jx_opt5.segment) if _jx_opt5 is not None else None); })(segments.pop())) or 0);
    }
    if (len(segments) == 0) {
        return (newCursor as float);
    }
    last = (segments[(len(segments) - 1)] as any);
    if ((lambda (_jx_opt6: any) -> any { return (_jx_opt6(last.segment) if _jx_opt6 is not None else None); })(isAtomic)) {
        newCursor -= len(last.segment);
    }
    elif last.isWordLike {
        segment = last.segment;
        matches = [*segment.matchAll(RegExp(PUNCTUATION_REGEX, "g"))];
        if (len(matches) <= 0) {
            newCursor -= len(segment);
        }
        else {
            lastMatch = (matches[(len(matches) - 1)] as any);
            newCursor -= (len(segment) - (lastMatch.index + len(lastMatch[0])));
        }
    }
    else {
        while ((((len(segments) > 0) and not ((lambda (_jx_opt7: any) -> any { return (_jx_opt7((((lambda (_jx_opt8: any) -> any { return (_jx_opt8.segment if _jx_opt8 is not None else None); })(segments[(len(segments) - 1)])) or "")) if _jx_opt7 is not None else None); })(isAtomic))) and not ((lambda (_jx_opt9: any) -> any { return (_jx_opt9.isWordLike if _jx_opt9 is not None else None); })(segments[(len(segments) - 1)]))) and not isWhitespaceChar((((lambda (_jx_opt10: any) -> any { return (_jx_opt10.segment if _jx_opt10 is not None else None); })(segments[(len(segments) - 1)])) or ""))) {
            newCursor -= (((lambda (_jx_opt11: any) -> any { return (len(_jx_opt11.segment) if _jx_opt11 is not None else None); })(segments.pop())) or 0);
        }
    }
    return (newCursor as float);
}

def:pub findWordForward(text: str, cursor: float, options: any) -> float {
    if (cursor >= len(text)) {
        return len(text);
    }
    textAfterCursor = text[cursor:];
    segmentFn = ((lambda (_jx_opt12: any) -> any { return (_jx_opt12.segment if _jx_opt12 is not None else None); })(options));
    isAtomic = ((lambda (_jx_opt13: any) -> any { return (_jx_opt13.isAtomicSegment if _jx_opt13 is not None else None); })(options));
    segments = (segmentFn(textAfterCursor) if segmentFn else wordSegmenter.segment(textAfterCursor));
    iterator = segments[Symbol.iterator]();
    next_j = iterator.next();
    newCursor = cursor;
    while ((not next_j.done and not ((lambda (_jx_opt14: any) -> any { return (_jx_opt14(next_j.value.segment) if _jx_opt14 is not None else None); })(isAtomic))) and isWhitespaceChar(next_j.value.segment)) {
        newCursor += int(len(next_j.value.segment));
        next_j = iterator.next();
    }
    if next_j.done {
        return (newCursor as float);
    }
    if ((lambda (_jx_opt15: any) -> any { return (_jx_opt15(next_j.value.segment) if _jx_opt15 is not None else None); })(isAtomic)) {
        newCursor += int(len(next_j.value.segment));
    }
    elif next_j.value.isWordLike {
        newCursor += ((lambda (_jx_null17: any) -> any { return (_jx_null17 if _jx_null17 is not None else len(next_j.value.segment)); })(((lambda (_jx_opt16: any) -> any { return (_jx_opt16.index if _jx_opt16 is not None else None); })(PUNCTUATION_REGEX.exec(next_j.value.segment)))));
    }
    else {
        while (((not next_j.done and not ((lambda (_jx_opt18: any) -> any { return (_jx_opt18(next_j.value.segment) if _jx_opt18 is not None else None); })(isAtomic))) and not next_j.value.isWordLike) and not isWhitespaceChar(next_j.value.segment)) {
            newCursor += int(len(next_j.value.segment));
            next_j = iterator.next();
        }
    }
    return (newCursor as float);
}
