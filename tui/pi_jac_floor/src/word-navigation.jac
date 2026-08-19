import from "./utils.jac" { getWordSegmenter, isWhitespaceChar, PUNCTUATION_REGEX }

glob wordSegmenter = getWordSegmenter();

def:pub findWordBackward(text: str, cursor: float, options: any) -> float {
    if (cursor <= 0) {
        return 0;
    }
    textBeforeCursor = text[0:cursor];
    segmentFn = (options.segment if options is not None else None);
    isAtomic = (options.isAtomicSegment if options is not None else None);
    segments = ([*segmentFn(textBeforeCursor)] if segmentFn else [*wordSegmenter.segment(textBeforeCursor)]);
    newCursor = cursor;
    # JS2JAC-HOLE[E7214]:
    # | while (
    # | 		segments.length > 0 &&
    # | 		!isAtomic?.(segments[segments.length - 1]?.segment || "") &&
    # | 		isWhitespaceChar(segments[segments.length - 1]?.segment || "")
    # | 	) {
    # | 		newCursor -= segments.pop()?.segment.length || 0;
    # | 	}
    if (len(segments) == 0) {
        return (newCursor as float);
    }
    last = (segments[(len(segments) - 1)] as any);
    # JS2JAC-HOLE[E7214]:
    # | if (isAtomic?.(last.segment)) {
    # | 		// Skip one atomic segment.
    # | 		newCursor -= last.segment.length;
    # | 	} else if (last.isWordLike) {
    # | 		// Skip inside one word-like segment, preserving ASCII punctuation boundaries.
    # | 		const segment = last.segment;
    # | 		const matches = [...segment.matchAll(new RegExp(PUNCTUATION_REGEX, "g"))];
    # | 		if (matches.length <= 0) {
    # | 			newCursor -= segment.length;
    # | 		} else {
    # | 			const lastMatch = matches[matches.length - 1]!;
    # | 			newCursor -= segment.length - (lastMatch.index + lastMatch[0].length);
    # | 		}
    # | 	} else {
    # | 		// Skip non-word non-whitespace run (punctuation)
    # | 		while (
    # | 			segments.length > 0 &&
    # | 			!isAtomic?.(segments[segments.length - 1]?.segment || "") &&
    # | 			!segments[segments.length - 1]?.isWordLike &&
    # | 			!isWhitespaceChar(segments[segments.length - 1]?.segment || "")
    # | 		) {
    # | 			newCursor -= segments.pop()?.segment.length || 0;
    # | 		}
    # | 	}
    return (newCursor as float);
}

def:pub findWordForward(text: str, cursor: float, options: any) -> float {
    if (cursor >= len(text)) {
        return len(text);
    }
    textAfterCursor = text[cursor:];
    segmentFn = (options.segment if options is not None else None);
    isAtomic = (options.isAtomicSegment if options is not None else None);
    segments = (segmentFn(textAfterCursor) if segmentFn else wordSegmenter.segment(textAfterCursor));
    iterator = segments[Symbol.iterator]();
    next_j = iterator.next();
    newCursor = cursor;
    while ((not next_j.done and not (isAtomic(next_j.value.segment) if isAtomic is not None else None)) and isWhitespaceChar(next_j.value.segment)) {
        newCursor += int(len(next_j.value.segment));
        next_j = iterator.next();
    }
    if next_j.done {
        return (newCursor as float);
    }
    # JS2JAC-HOLE[E7214]:
    # | if (isAtomic?.(next.value.segment)) {
    # | 		// Skip one atomic segment.
    # | 		newCursor += next.value.segment.length;
    # | 	} else if (next.value.isWordLike) {
    # | 		// Skip inside one word-like segment, preserving ASCII punctuation boundaries.
    # | 		newCursor += PUNCTUATION_REGEX.exec(next.value.segment)?.index ?? next.value.segment.length;
    # | 	} else {
    # | 		// Skip non-word non-whitespace run (punctuation)
    # | 		while (
    # | 			!next.done &&
    # | 			!isAtomic?.(next.value.segment) &&
    # | 			!next.value.isWordLike &&
    # | 			!isWhitespaceChar(next.value.segment)
    # | 		) {
    # | 			newCursor += next.value.segment.length;
    # | 			next = iterator.next();
    # | 		}
    # | 	}
    return (newCursor as float);
}
