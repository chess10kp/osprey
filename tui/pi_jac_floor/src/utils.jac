import from re { compile, search, sub }
import from .unicode_support {
    GraphemeSegmenter, WordSegmenter, CjkBreakRegex,
    eastAsianWidth, isZeroWidth, stripLeadingNonPrinting, isRgiEmoji
}

glob graphemeSegmenter: any = GraphemeSegmenter();

glob wordSegmenter: any = WordSegmenter();

def:pub getGraphemeSegmenter() -> any {
    return graphemeSegmenter;
}

def:pub getWordSegmenter() -> any {
    return wordSegmenter;
}

def couldBeEmoji(segment: str) -> bool {
    cp = (ord(segment[0]) as any);
    return (((((((cp >= 126976) and (cp <= 130047)) or ((cp >= 8960) and (cp <= 9215))) or ((cp >= 9728) and (cp <= 10175))) or ((cp >= 11088) and (cp <= 11093))) or ("️" in segment)) or (len(segment) > 2));
}

glob WIDTH_CACHE_SIZE = 512;

glob widthCache = {};

glob:pub cjkBreakRegex = CjkBreakRegex();

def isPrintableAscii(str_j: str) -> bool {
    i: int = 0;
    while (i < len(str_j)) {
        code = ord(str_j[i]);
        if ((code < 32) or (code > 126)) {
            return False;
        }
        i += 1;
    }
    return True;
}

def truncateFragmentToWidth(text: str, maxWidth: float) -> dict[str, str | float] {
    if ((maxWidth <= 0) or (len(text) == 0)) {
        return {"text": "", "width": 0};
    }
    if isPrintableAscii(text) {
        clipped = text[0:maxWidth];
        return {"text": clipped, "width": len(clipped)};
    }
    hasAnsi = ("\u001b" in text);
    hasTabs = ("\t" in text);
    if (not hasAnsi and not hasTabs) {
        result: str = "";
        width: float = float(0);
        for _jx_item0 in graphemeSegmenter.segment(text) {
            segment: str = (_jx_item0.segment as str);
            w: float = float(graphemeWidth(segment));
            if ((width + w) > maxWidth) {
                break;
            }
            result += segment;
            width = float(width + w);
        }
        return {"text": result, "width": width};
    }
    result: str = "";
    width: float = float(0);
    i = 0;
    pendingAnsi: str = "";
    while (i < len(text)) {
        ansi = extractAnsiCode(text, i);
        if ansi {
            pendingAnsi += (ansi["code"] as str);
            i += int((ansi["length"] as float));
            continue;
        }
        if (text[i] == "\t") {
            if ((width + 3) > maxWidth) {
                break;
            }
            if pendingAnsi {
                result += pendingAnsi;
                pendingAnsi = "";
            }
            result += "\t";
            width = float(width + 3);
            i += 1;
            continue;
        }
        end = i;
        while ((end < len(text)) and (text[end] != "\t")) {
            nextAnsi = extractAnsiCode(text, end);
            if nextAnsi {
                break;
            }
            end += 1;
        }
        for _jx_item0 in graphemeSegmenter.segment(text[i:end]) {
            segment: str = (_jx_item0.segment as str);
            w: float = float(graphemeWidth(segment));
            if ((width + w) > maxWidth) {
                return {"text": result, "width": width};
            }
            if pendingAnsi {
                result += pendingAnsi;
                pendingAnsi = "";
            }
            result += segment;
            width = float(width + w);
        }
        i = end;
    }
    return {"text": result, "width": width};
}

def finalizeTruncatedResult(prefix: str, prefixWidth: float, ellipsis: str, ellipsisWidth: float, maxWidth: float, pad: bool) -> str {
    reset: str = "\u001b[0m";
    visibleWidth = (prefixWidth + ellipsisWidth);
    result: str;
    if (len(ellipsis) > 0) {
        result = f"{prefix}{reset}{ellipsis}{reset}";
    }
    else {
        result = f"{prefix}{reset}";
    }
    return ((result + (" " * int(max(float(0), float((maxWidth - visibleWidth)))))) if pad else result);
}

def graphemeWidth(segment: str) -> float {
    if (segment == "\t") {
        return 3;
    }
    if isZeroWidth(segment) {
        return 0;
    }
    if (couldBeEmoji(segment) and isRgiEmoji(segment)) {
        return 2;
    }
    base = stripLeadingNonPrinting(segment);
    cp = ord(base[0]);
    if (cp == None) {
        return 0;
    }
    if ((cp >= 127462) and (cp <= 127487)) {
        return 2;
    }
    width = eastAsianWidth(cp);
    if (len(segment) > 1) {
        for char in segment[1:] {
            c = (ord(char[0]) as any);
            if ((c >= 65280) and (c <= 65519)) {
                width += eastAsianWidth(c);
            }
            elif ((c == 3635) or (c == 3763)) {
                width += 1;
            }
        }
    }
    return (width as float);
}

def:pub visibleWidth(str_j: str) -> float {
    if (len(str_j) == 0) {
        return 0;
    }
    if isPrintableAscii(str_j) {
        return len(str_j);
    }
    cached = widthCache.get(str_j);
    if (cached != None) {
        return (cached as float);
    }
    clean = str_j;
    if ("\t" in str_j) {
        clean = clean.replace("\t", "   ");
    }
    if ("\u001b" in clean) {
        stripped: str = "";
        i = 0;
        while (i < len(clean)) {
            ansi = extractAnsiCode(clean, i);
            if ansi {
                i += int((ansi["length"] as float));
                continue;
            }
            stripped += clean[i];
            i += 1;
        }
        clean = stripped;
    }
    width: float = float(0);
    for _jx_item0 in graphemeSegmenter.segment(clean) {
        segment: str = (_jx_item0.segment as str);
        width = float(width + graphemeWidth(segment));
    }
    if (len(widthCache) >= WIDTH_CACHE_SIZE) {
        firstKey = next(iter(widthCache.keys()), None);
        if (firstKey != None) {
            widthCache.pop(firstKey, None);
        }
    }
    widthCache[str_j] = width;
    return (width as float);
}

glob THAI_LAO_AM_REGEX = compile(r"[\u0e33\u0eb3]");

glob THAI_LAO_AM_GLOBAL_REGEX = compile(r"[\u0e33\u0eb3]");

def:pub normalizeTerminalOutput(str_j: str) -> str {
    if not (search(THAI_LAO_AM_REGEX, str_j) is not None) {
        return str_j;
    }
    return sub(THAI_LAO_AM_GLOBAL_REGEX, lambda (char: any) -> any { return ("ํา" if (char == "ำ") else "ໍາ"); }, str_j);
}

def:pub extractAnsiCode(str_j: str, pos: float) -> dict[str, str | float] | None {
    if ((pos >= len(str_j)) or (str_j[pos] != "\u001b")) {
        return None;
    }
    next_j = str_j[(pos + 1)];
    if (next_j == "[") {
        j = (pos + 2);
        while ((j < len(str_j)) and not (search(r"[mGKHJ]", (str_j[j] as any)) is not None)) {
            j += 1;
        }
        if (j < len(str_j)) {
            return {"code": str_j[pos:(j + 1)], "length": ((j + 1) - pos)};
        }
        return None;
    }
    if (next_j == "]") {
        j = (pos + 2);
        while (j < len(str_j)) {
            if (str_j[j] == "\u0007") {
                return {"code": str_j[pos:(j + 1)], "length": ((j + 1) - pos)};
            }
            if ((str_j[j] == "\u001b") and (str_j[(j + 1)] == "\\")) {
                return {"code": str_j[pos:(j + 2)], "length": ((j + 2) - pos)};
            }
            j += 1;
        }
        return None;
    }
    if (next_j == "_") {
        j = (pos + 2);
        while (j < len(str_j)) {
            if (str_j[j] == "\u0007") {
                return {"code": str_j[pos:(j + 1)], "length": ((j + 1) - pos)};
            }
            if ((str_j[j] == "\u001b") and (str_j[(j + 1)] == "\\")) {
                return {"code": str_j[pos:(j + 2)], "length": ((j + 2) - pos)};
            }
            j += 1;
        }
        return None;
    }
    return None;
}

def parseOsc8Hyperlink(ansiCode: str) -> any | None {
    if not ansiCode.startswith("\u001b]8;") {
        return None;
    }
    terminator: any = ("\u0007" if ansiCode.endswith("\u0007") else "\u001b\\");
    body = ansiCode[4:(-1 if (terminator == "\u0007") else -2)];
    separatorIndex = (-1 if ";" not in body else body.index(";"));
    if (separatorIndex == -1) {
        return None;
    }
    params = body[0:separatorIndex];
    url = body[(separatorIndex + 1):];
    if not url {
        return None;
    }
    return {"params": params, "url": url, "terminator": terminator};
}

def formatOsc8Hyperlink(hyperlink: any) -> str {
    return f"\\x1b]8;{hyperlink.params};{hyperlink.url}{hyperlink.terminator}";
}

def formatOsc8Close(terminator: any) -> str {
    return f"\\x1b]8;;{terminator}";
}

obj AnsiCodeTracker {
    has bold: bool = False;
    has dim: bool = False;
    has italic: bool = False;
    has underline: bool = False;
    has blink: bool = False;
    has inverse: bool = False;
    has hidden: bool = False;
    has strikethrough: bool = False;
    has fgColor: str | None = None;
    has bgColor: str | None = None;
    has activeHyperlink: any | None = None;
    def process(ansiCode: str) -> None {
        hyperlink = parseOsc8Hyperlink(ansiCode);
        if (hyperlink != None) {
            self.activeHyperlink = hyperlink;
            return;
        }
        if not ansiCode.endswith("m") {
            return;
        }
        match_j = search(r"\x1b\[([\d;]*)m", ansiCode);
        if not match_j {
            return;
        }
        params = match_j.group(1);
        if ((params == "") or (params == "0")) {
            self.reset();
            return;
        }
        parts = params.split(";");
        i = 0;
        while (i < len(parts)) {
            code = int(parts[i], 10);
            if ((code == 38) or (code == 48)) {
                if ((parts[(i + 1)] == "5") and (parts[(i + 2)] != None)) {
                    colorCode: str = f"{parts[i]};{parts[(i + 1)]};{parts[(i + 2)]}";
                    if (code == 38) {
                        self.fgColor = colorCode;
                    }
                    else {
                        self.bgColor = colorCode;
                    }
                    i += 3;
                    continue;
                }
                elif ((parts[(i + 1)] == "2") and (parts[(i + 4)] != None)) {
                    colorCode: str = f"{parts[i]};{parts[(i + 1)]};{parts[(i + 2)]};{parts[(i + 3)]};{parts[(i + 4)]}";
                    if (code == 38) {
                        self.fgColor = colorCode;
                    }
                    else {
                        self.bgColor = colorCode;
                    }
                    i += 5;
                    continue;
                }
            }
            _sw = code;
            if (_sw == 0) {
                self.reset();
            }
            elif (_sw == 1) {
                self.bold = True;
            }
            elif (_sw == 2) {
                self.dim = True;
            }
            elif (_sw == 3) {
                self.italic = True;
            }
            elif (_sw == 4) {
                self.underline = True;
            }
            elif (_sw == 5) {
                self.blink = True;
            }
            elif (_sw == 7) {
                self.inverse = True;
            }
            elif (_sw == 8) {
                self.hidden = True;
            }
            elif (_sw == 9) {
                self.strikethrough = True;
            }
            elif (_sw == 21) {
                self.bold = False;
            }
            elif (_sw == 22) {
                self.bold = False;
                self.dim = False;
            }
            elif (_sw == 23) {
                self.italic = False;
            }
            elif (_sw == 24) {
                self.underline = False;
            }
            elif (_sw == 25) {
                self.blink = False;
            }
            elif (_sw == 27) {
                self.inverse = False;
            }
            elif (_sw == 28) {
                self.hidden = False;
            }
            elif (_sw == 29) {
                self.strikethrough = False;
            }
            elif (_sw == 39) {
                self.fgColor = None;
            }
            elif (_sw == 49) {
                self.bgColor = None;
            }
            else {
                if (((code >= 30) and (code <= 37)) or ((code >= 90) and (code <= 97))) {
                    self.fgColor = str(code);
                }
                elif (((code >= 40) and (code <= 47)) or ((code >= 100) and (code <= 107))) {
                    self.bgColor = str(code);
                }
            }
            i += 1;
        }
    }
    def reset() -> None {
        self.bold = False;
        self.dim = False;
        self.italic = False;
        self.underline = False;
        self.blink = False;
        self.inverse = False;
        self.hidden = False;
        self.strikethrough = False;
        self.fgColor = None;
        self.bgColor = None;
    }
    def clear() -> None {
        self.reset();
        self.activeHyperlink = None;
    }
    def getActiveCodes() -> str {
        codes: list[str] = [];
        if self.bold {
            codes.append("1");
        }
        if self.dim {
            codes.append("2");
        }
        if self.italic {
            codes.append("3");
        }
        if self.underline {
            codes.append("4");
        }
        if self.blink {
            codes.append("5");
        }
        if self.inverse {
            codes.append("7");
        }
        if self.hidden {
            codes.append("8");
        }
        if self.strikethrough {
            codes.append("9");
        }
        if self.fgColor {
            codes.append(self.fgColor);
        }
        if self.bgColor {
            codes.append(self.bgColor);
        }
        result = (f"\\x1b[{";".join(codes)}m" if (len(codes) > 0) else "");
        if self.activeHyperlink {
            result += formatOsc8Hyperlink(self.activeHyperlink);
        }
        return result;
    }
    def hasActiveCodes() -> bool {
        return ((((((((((self.bold or self.dim) or self.italic) or self.underline) or self.blink) or self.inverse) or self.hidden) or self.strikethrough) or (self.fgColor != None)) or (self.bgColor != None)) or (self.activeHyperlink != None));
    }
    def getLineEndReset() -> str {
        result: str = "";
        if self.underline {
            result += "\u001b[24m";
        }
        if self.activeHyperlink {
            result += formatOsc8Close(self.activeHyperlink.terminator);
        }
        return result;
    }
}

def updateTrackerFromText(text: str, tracker: AnsiCodeTracker) -> None {
    i = 0;
    while (i < len(text)) {
        ansiResult = extractAnsiCode(text, i);
        if ansiResult {
            tracker.process((ansiResult["code"] as str));
            i += int((ansiResult["length"] as float));
        }
        else {
            i += 1;
        }
    }
}

def splitIntoTokensWithAnsi(text: str) -> list[str] {
    tokens: list[str] = [];
    current: str = "";
    pendingAnsi: str = "";
    currentKind: any | None = None;
    i = 0;
    # NOTE(port): the js2jac output emitted `flushCurrent` as a lambda that
    # reassigns the captured `current`/`currentKind` locals. Python closures
    # cannot rebind captured names without `nonlocal`, so that both crashed
    # (UnboundLocalError) and would have lost mutations. Inlined at both call
    # sites below to preserve the original tokenizer semantics.
    while (i < len(text)) {
        ansiResult = extractAnsiCode(text, i);
        if ansiResult {
            pendingAnsi += (ansiResult["code"] as str);
            i += int((ansiResult["length"] as float));
            continue;
        }
        end = i;
        while ((end < len(text)) and not extractAnsiCode(text, end)) {
            end += 1;
        }
        for _jx_item0 in graphemeSegmenter.segment(text[i:end]) {
            segment: str = (_jx_item0.segment as str);
            segmentIsSpace = (segment == " ");
            if (not segmentIsSpace and cjkBreakRegex.test(segment)) {
                if current {
                    tokens.append(current);
                    current = "";
                    currentKind = None;
                }
                token = (pendingAnsi + segment);
                pendingAnsi = "";
                tokens.append(token);
                continue;
            }
            segmentKind = ("space" if segmentIsSpace else "word");
            if (current and (currentKind != segmentKind)) {
                if current {
                    tokens.append(current);
                    current = "";
                    currentKind = None;
                }
            }
            if pendingAnsi {
                current += pendingAnsi;
                pendingAnsi = "";
            }
            currentKind = segmentKind;
            current += segment;
        }
        i = end;
    }
    if pendingAnsi {
        if current {
            current += pendingAnsi;
        }
        elif (len(tokens) > 0) {
            tokens[(len(tokens) - 1)] += pendingAnsi;
        }
        else {
            current = pendingAnsi;
        }
    }
    if current {
        tokens.append(current);
    }
    return tokens;
}

def:pub wrapTextWithAnsi(text: str, width: float) -> list[str] {
    if not text {
        return [""];
    }
    inputLines = text.split("\n");
    result: list[str] = [];
    tracker = AnsiCodeTracker();
    for inputLine in inputLines {
        prefix = (tracker.getActiveCodes() if (len(result) > 0) else "");
        wrappedLines = wrapSingleLine((prefix + inputLine), width);
        for wrappedLine in wrappedLines {
            result.append(wrappedLine);
        }
        updateTrackerFromText(inputLine, tracker);
    }
    return (result if (len(result) > 0) else [""]);
}

def wrapSingleLine(line: str, width: float) -> list[str] {
    if not line {
        return [""];
    }
    visibleLength: float = float(visibleWidth(line));
    if (visibleLength <= width) {
        return [line];
    }
    wrapped: list[str] = [];
    tracker = AnsiCodeTracker();
    tokens = splitIntoTokensWithAnsi(line);
    currentLine: str = "";
    currentVisibleLength: float = float(0);
    for token in tokens {
        tokenVisibleLength: float = float(visibleWidth(token));
        isWhitespace = (token.strip() == "");
        if ((tokenVisibleLength > width) and not isWhitespace) {
            if currentLine {
                lineEndReset = tracker.getLineEndReset();
                if lineEndReset {
                    currentLine += lineEndReset;
                }
                wrapped.append(currentLine);
                currentLine = "";
                currentVisibleLength = 0;
            }
            broken = breakLongWord(token, width, tracker);
            i: int = 0;
            while (i < (len(broken) - 1)) {
                wrapped.append((broken[i] as any));
                i += 1;
            }
            currentLine = broken[(len(broken) - 1)];
            currentVisibleLength = visibleWidth(currentLine);
            continue;
        }
        totalNeeded: float = float((currentVisibleLength + tokenVisibleLength));
        if ((totalNeeded > width) and (currentVisibleLength > 0)) {
            lineToWrap: str = currentLine.rstrip();
            lineEndReset = tracker.getLineEndReset();
            if lineEndReset {
                lineToWrap += lineEndReset;
            }
            wrapped.append(lineToWrap);
            if isWhitespace {
                currentLine = tracker.getActiveCodes();
                currentVisibleLength = 0;
            }
            else {
                currentLine = (tracker.getActiveCodes() + token);
                currentVisibleLength = tokenVisibleLength;
            }
        }
        else {
            currentLine += token;
            currentVisibleLength = float(currentVisibleLength + tokenVisibleLength);
        }
        updateTrackerFromText(token, tracker);
    }
    if currentLine {
        wrapped.append(currentLine);
    }
    return ([line.rstrip() for line in wrapped] if (len(wrapped) > 0) else [""]);
}

glob:pub PUNCTUATION_REGEX = compile(r"""[(){}[\]<>.,;:'"!?+\-=*/\\|&%^$#@~`]""");

def:pub isWhitespaceChar(char: str) -> bool {
    return (search(r"\s", char) is not None);
}

def:pub isPunctuationChar(char: str) -> bool {
    return (search(PUNCTUATION_REGEX, char) is not None);
}

def breakLongWord(word: str, width: float, tracker: AnsiCodeTracker) -> list[str] {
    lines: list[str] = [];
    currentLine = tracker.getActiveCodes();
    currentWidth: float = float(0);
    i = 0;
    segments: list[dict[str, any | str]] = [];
    while (i < len(word)) {
        ansiResult = extractAnsiCode(word, i);
        if ansiResult {
            segments.append({"type": "ansi", "value": (ansiResult["code"] as str)});
            i += int((ansiResult["length"] as float));
        }
        else {
            end = i;
            while (end < len(word)) {
                nextAnsi = extractAnsiCode(word, end);
                if nextAnsi {
                    break;
                }
                end += 1;
            }
            textPortion = word[i:end];
            for seg in graphemeSegmenter.segment(textPortion) {
                segments.append({"type": "grapheme", "value": seg.segment});
            }
            i = end;
        }
    }
    for seg in segments {
        if ((seg["type"] as any) == "ansi") {
            currentLine += (seg["value"] as str);
            tracker.process((seg["value"] as str));
            continue;
        }
        grapheme = (seg["value"] as str);
        if not grapheme {
            continue;
        }
        graphemeWidth: float = float(visibleWidth(grapheme));
        if ((currentWidth + graphemeWidth) > width) {
            lineEndReset = tracker.getLineEndReset();
            if lineEndReset {
                currentLine += lineEndReset;
            }
            lines.append(currentLine);
            currentLine = tracker.getActiveCodes();
            currentWidth = 0;
        }
        currentLine += grapheme;
        currentWidth = float(currentWidth + graphemeWidth);
    }
    if currentLine {
        lines.append(currentLine);
    }
    return (lines if (len(lines) > 0) else [""]);
}

def:pub applyBackgroundToLine(line: str, width: float, bgFn: any) -> str {
    visibleLen: float = float(visibleWidth(line));
    paddingNeeded = max(float(0), float((width - visibleLen)));
    padding = (" " * int(paddingNeeded));
    withPadding = (line + padding);
    return bgFn(withPadding);
}

def:pub truncateToWidth(text: str, maxWidth: float, ellipsis: str = "...", pad: bool = False) -> str {
    if (maxWidth <= 0) {
        return "";
    }
    if (len(text) == 0) {
        return ((" " * int(maxWidth)) if pad else "");
    }
    ellipsisWidth: float = float(visibleWidth(ellipsis));
    if (ellipsisWidth >= maxWidth) {
        textWidth: float = float(visibleWidth(text));
        if (textWidth <= maxWidth) {
            return ((text + (" " * int((maxWidth - textWidth)))) if pad else text);
        }
        clippedEllipsis = truncateFragmentToWidth(ellipsis, maxWidth);
        if ((clippedEllipsis["width"] as float) == 0) {
            return ((" " * int(maxWidth)) if pad else "");
        }
        return finalizeTruncatedResult("", 0, (clippedEllipsis["text"] as str), (clippedEllipsis["width"] as float), maxWidth, pad);
    }
    if isPrintableAscii(text) {
        if (len(text) <= maxWidth) {
            return ((text + (" " * int((maxWidth - len(text))))) if pad else text);
        }
        targetWidth: float = float((maxWidth - ellipsisWidth));
        return finalizeTruncatedResult(text[0:int(targetWidth)], targetWidth, ellipsis, ellipsisWidth, maxWidth, pad);
    }
    targetWidth: float = float((maxWidth - ellipsisWidth));
    result: str = "";
    pendingAnsi: str = "";
    visibleSoFar: float = float(0);
    keptWidth: float = float(0);
    keepContiguousPrefix: bool = True;
    overflowed: bool = False;
    exhaustedInput: bool = False;
    hasAnsi = ("\u001b" in text);
    hasTabs = ("\t" in text);
    if (not hasAnsi and not hasTabs) {
        for _jx_item0 in graphemeSegmenter.segment(text) {
            segment: str = (_jx_item0.segment as str);
            width: float = float(graphemeWidth(segment));
            if (keepContiguousPrefix and ((keptWidth + width) <= targetWidth)) {
                result += segment;
                keptWidth = float(keptWidth + width);
            }
            else {
                keepContiguousPrefix = False;
            }
            visibleSoFar = float(visibleSoFar + width);
            if (visibleSoFar > maxWidth) {
                overflowed = True;
                break;
            }
        }
        exhaustedInput = not overflowed;
    }
    else {
        i = 0;
        while (i < len(text)) {
            ansi = extractAnsiCode(text, i);
            if ansi {
                pendingAnsi += (ansi["code"] as str);
                i += int((ansi["length"] as float));
                continue;
            }
            if (text[i] == "\t") {
                if (keepContiguousPrefix and ((keptWidth + 3) <= targetWidth)) {
                    if pendingAnsi {
                        result += pendingAnsi;
                        pendingAnsi = "";
                    }
                    result += "\t";
                    keptWidth = float(keptWidth + 3);
                }
                else {
                    keepContiguousPrefix = False;
                    pendingAnsi = "";
                }
                visibleSoFar = float(visibleSoFar + 3);
                if (visibleSoFar > maxWidth) {
                    overflowed = True;
                    break;
                }
                i += 1;
                continue;
            }
            end = i;
            while ((end < len(text)) and (text[end] != "\t")) {
                nextAnsi = extractAnsiCode(text, end);
                if nextAnsi {
                    break;
                }
                end += 1;
            }
            for _jx_item0 in graphemeSegmenter.segment(text[i:end]) {
                segment: str = (_jx_item0.segment as str);
                width: float = float(graphemeWidth(segment));
                if (keepContiguousPrefix and ((keptWidth + width) <= targetWidth)) {
                    if pendingAnsi {
                        result += pendingAnsi;
                        pendingAnsi = "";
                    }
                    result += segment;
                    keptWidth = float(keptWidth + width);
                }
                else {
                    keepContiguousPrefix = False;
                    pendingAnsi = "";
                }
                visibleSoFar = float(visibleSoFar + width);
                if (visibleSoFar > maxWidth) {
                    overflowed = True;
                    break;
                }
            }
            if overflowed {
                break;
            }
            i = end;
        }
        exhaustedInput = (i >= len(text));
    }
    if (not overflowed and exhaustedInput) {
        return ((text + (" " * int(max(float(0), float((maxWidth - visibleSoFar)))))) if pad else text);
    }
    return finalizeTruncatedResult(result, keptWidth, ellipsis, ellipsisWidth, maxWidth, pad);
}

def:pub sliceByColumn(line: str, startCol: float, length: float, strict: any = False) -> str {
    return (sliceWithWidth(line, startCol, length, strict)["text"] as str);
}

def:pub sliceWithWidth(line: str, startCol: float, length: float, strict: any = False) -> dict[str, str | float] {
    if (length <= 0) {
        return {"text": "", "width": 0};
    }
    endCol = (startCol + length);
    result: str = "";
    resultWidth: float = float(0);
    currentCol: float = float(0);
    i = 0;
    pendingAnsi: str = "";
    while (i < len(line)) {
        ansi = extractAnsiCode(line, i);
        if ansi {
            if ((currentCol >= startCol) and (currentCol < endCol)) {
                result += (ansi["code"] as str);
            }
            elif (currentCol < startCol) {
                pendingAnsi += (ansi["code"] as str);
            }
            i += int((ansi["length"] as float));
            continue;
        }
        textEnd = i;
        while ((textEnd < len(line)) and not extractAnsiCode(line, textEnd)) {
            textEnd += 1;
        }
        for _jx_item0 in graphemeSegmenter.segment(line[i:textEnd]) {
            segment: str = (_jx_item0.segment as str);
            w: float = float(graphemeWidth(segment));
            inRange: float = float(((currentCol >= startCol) and (currentCol < endCol)));
            fits: float = float((not strict or ((currentCol + w) <= endCol)));
            if (inRange and fits) {
                if pendingAnsi {
                    result += pendingAnsi;
                    pendingAnsi = "";
                }
                result += segment;
                resultWidth = float(resultWidth + w);
            }
            currentCol = float(currentCol + w);
            if (currentCol >= endCol) {
                break;
            }
        }
        i = textEnd;
        if (currentCol >= endCol) {
            break;
        }
    }
    return {"text": result, "width": resultWidth};
}

glob pooledStyleTracker = AnsiCodeTracker();

def:pub extractSegments(line: str, beforeEnd: float, afterStart: float, afterLen: float, strictAfter: any = False) -> dict[str, str | float] {
    before: str = "";
    beforeWidth: float = float(0);
    after: str = "";
    afterWidth: float = float(0);
    currentCol: float = float(0);
    i = 0;
    pendingAnsiBefore: str = "";
    afterStarted: bool = False;
    afterEnd = (afterStart + afterLen);
    pooledStyleTracker.clear();
    while (i < len(line)) {
        ansi = extractAnsiCode(line, i);
        if ansi {
            pooledStyleTracker.process((ansi["code"] as str));
            if (currentCol < beforeEnd) {
                pendingAnsiBefore += (ansi["code"] as str);
            }
            elif (((currentCol >= afterStart) and (currentCol < afterEnd)) and afterStarted) {
                after += (ansi["code"] as str);
            }
            i += int((ansi["length"] as float));
            continue;
        }
        textEnd = i;
        while ((textEnd < len(line)) and not extractAnsiCode(line, textEnd)) {
            textEnd += 1;
        }
        for _jx_item0 in graphemeSegmenter.segment(line[i:textEnd]) {
            segment: str = (_jx_item0.segment as str);
            w: float = float(graphemeWidth(segment));
            if ((currentCol < beforeEnd) and ((currentCol + w) <= beforeEnd)) {
                if pendingAnsiBefore {
                    before += pendingAnsiBefore;
                    pendingAnsiBefore = "";
                }
                before += segment;
                beforeWidth = float(beforeWidth + w);
            }
            elif ((currentCol >= afterStart) and (currentCol < afterEnd)) {
                fits: float = float((not strictAfter or ((currentCol + w) <= afterEnd)));
                if fits {
                    if not afterStarted {
                        after += pooledStyleTracker.getActiveCodes();
                        afterStarted = True;
                    }
                    after += segment;
                    afterWidth = float(afterWidth + w);
                }
            }
            currentCol = float(currentCol + w);
            if ((currentCol >= beforeEnd) if (afterLen <= 0) else (currentCol >= afterEnd)) {
                break;
            }
        }
        i = textEnd;
        if ((currentCol >= beforeEnd) if (afterLen <= 0) else (currentCol >= afterEnd)) {
            break;
        }
    }
    return {"before": before, "beforeWidth": beforeWidth, "after": after, "afterWidth": afterWidth};
}
