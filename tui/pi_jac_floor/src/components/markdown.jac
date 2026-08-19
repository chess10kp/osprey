# interop import: marked { Marked, Tokenizer }
import from "../terminal-image.jac" { getCapabilities, hyperlink, isImageLine }
import from "../utils.jac" { applyBackgroundToLine, visibleWidth, wrapTextWithAnsi }
import from re { compile, split, sub }

glob STRICT_STRIKETHROUGH_REGEX = compile(r"^(~~)(?=[^\s~])((?:\\.|[^\\])*?(?:\\.|[^\s~\\]))\1(?=[^~]|$)");

obj StrictStrikethroughTokenizer(Tokenizer) {
    has lexer: any = None;
    override def del(src: str) -> any | None {
        match_j = STRICT_STRIKETHROUGH_REGEX.exec(src);
        if not match_j {
            return None;
        }
        text = match_j[2];
        return {"type": "del", "raw": match_j[0], "text": text, "tokens": self.lexer.inlineTokens(text)};
    }
}

def trimPartialClosingFences(tokens: any) -> None {
    token = tokens[(len(tokens) - 1)];
    if (((lambda (_jx_opt0: any) -> any { return (_jx_opt0.type if _jx_opt0 is not None else None); })(token)) == "list") {
        trimPartialClosingFences(((lambda (_jx_null2: any) -> any { return (_jx_null2 if _jx_null2 is not None else []); })(((lambda (_jx_opt1: any) -> any { return (_jx_opt1.tokens if _jx_opt1 is not None else None); })(token.items[(len(token.items) - 1)])))));
        return;
    }
    if (((lambda (_jx_opt3: any) -> any { return (_jx_opt3.type if _jx_opt3 is not None else None); })(token)) == "blockquote") {
        trimPartialClosingFences(((lambda (_jx_null4: any) -> any { return (_jx_null4 if _jx_null4 is not None else []); })(token.tokens)));
        return;
    }
    if (((lambda (_jx_opt5: any) -> any { return (_jx_opt5.type if _jx_opt5 is not None else None); })(token)) != "code") {
        return;
    }
    marker = ((lambda (_jx_opt6: any) -> any { return (_jx_opt6[1] if _jx_opt6 is not None else None); })(compile(r"^(`{3,}|~{3,})").exec(token.raw)));
    lastLine = token.raw.split("\n").pop();
    if (((not marker or not lastLine) or (len(lastLine) >= len(marker))) or (lastLine != ((lambda (_jx_opt7: any) -> any { return (_jx_opt7.repeat(len(lastLine)) if _jx_opt7 is not None else None); })(marker[0])))) {
        return;
    }
    token.text = sub(r"\n$", "", token.text[0:-len(lastLine)]);
}

glob markdownParser: any = Marked();

obj:pub Markdown {
    has text: str;
    has paddingX: float;
    has paddingY: float;
    has defaultTextStyle: any | None = None;
    has theme: any;
    has options: any;
    has defaultStylePrefix: str | None = None;
    has cachedText: str | None = None;
    has cachedWidth: float | None = None;
    has cachedLines: list[str] | None = None;
    def __init__(text: str, paddingX: float, paddingY: float, theme: any, defaultTextStyle: any | None = None, options: any | None = None) -> None {
        self.text = text;
        self.paddingX = paddingX;
        self.paddingY = paddingY;
        self.theme = theme;
        self.defaultTextStyle = defaultTextStyle;
        self.options = ({**options} if options else {});
    }
    def setText(text: str) -> None {
        self.text = text;
        self.invalidate();
    }
    def invalidate() -> None {
        self.cachedText = None;
        self.cachedWidth = None;
        self.cachedLines = None;
    }
    def render(width: float) -> list[str] {
        if ((self.cachedLines and (self.cachedText == self.text)) and (self.cachedWidth == width)) {
            return self.cachedLines;
        }
        contentWidth = max(float(1), float((width - (self.paddingX * 2))));
        if (not self.text or (self.text.strip() == "")) {
            result: list[str] = [];
            self.cachedText = self.text;
            self.cachedWidth = width;
            self.cachedLines = result;
            return result;
        }
        normalizedText = self.text.replace("\t", "   ");
        tokens = markdownParser.lexer(normalizedText);
        trimPartialClosingFences(tokens);
        renderedLines: list[str] = [];
        i: int = 0;
        while (i < len(tokens)) {
            token = tokens[i];
            nextToken = tokens[(i + 1)];
            tokenLines = self.renderToken(token, contentWidth, ((lambda (_jx_opt8: any) -> any { return (_jx_opt8.type if _jx_opt8 is not None else None); })(nextToken)));
            for tokenLine in tokenLines {
                renderedLines.append(tokenLine);
            }
            i += 1;
        }
        wrappedLines: list[str] = [];
        for line in renderedLines {
            if isImageLine(line) {
                wrappedLines.append(line);
            }
            else {
                for wrappedLine in wrapTextWithAnsi(line, contentWidth) {
                    wrappedLines.append(wrappedLine);
                }
            }
        }
        leftMargin = (" " * int(self.paddingX));
        rightMargin = (" " * int(self.paddingX));
        bgFn = ((lambda (_jx_opt9: any) -> any { return (_jx_opt9.bgColor if _jx_opt9 is not None else None); })(self.defaultTextStyle));
        contentLines: list[str] = [];
        for line in wrappedLines {
            if isImageLine(line) {
                contentLines.append(line);
                continue;
            }
            lineWithMargins = ((leftMargin + line) + rightMargin);
            if bgFn {
                contentLines.append(applyBackgroundToLine(lineWithMargins, width, bgFn));
            }
            else {
                visibleLen = visibleWidth(lineWithMargins);
                paddingNeeded = max(float(0), float((width - visibleLen)));
                contentLines.append((lineWithMargins + (" " * int(paddingNeeded))));
            }
        }
        emptyLine = (" " * int(width));
        emptyLines: list[str] = [];
        i: int = 0;
        while (i < self.paddingY) {
            line = (applyBackgroundToLine(emptyLine, width, bgFn) if bgFn else emptyLine);
            emptyLines.append(line);
            i += 1;
        }
        result = emptyLines.concat(contentLines, emptyLines);
        self.cachedText = self.text;
        self.cachedWidth = width;
        self.cachedLines = result;
        return (result if (len(result) > 0) else [""]);
    }
    def applyDefaultStyle(text: str) -> str {
        if not self.defaultTextStyle {
            return text;
        }
        styled = text;
        if self.defaultTextStyle.color {
            styled = self.defaultTextStyle.color(styled);
        }
        if self.defaultTextStyle.bold {
            styled = self.theme.bold(styled);
        }
        if self.defaultTextStyle.italic {
            styled = self.theme.italic(styled);
        }
        if self.defaultTextStyle.strikethrough {
            styled = self.theme.strikethrough(styled);
        }
        if self.defaultTextStyle.underline {
            styled = self.theme.underline(styled);
        }
        return styled;
    }
    def getDefaultStylePrefix() -> str {
        if not self.defaultTextStyle {
            return "";
        }
        if (self.defaultStylePrefix != None) {
            return self.defaultStylePrefix;
        }
        sentinel: str = "\u0000";
        styled = sentinel;
        if self.defaultTextStyle.color {
            styled = self.defaultTextStyle.color(styled);
        }
        if self.defaultTextStyle.bold {
            styled = self.theme.bold(styled);
        }
        if self.defaultTextStyle.italic {
            styled = self.theme.italic(styled);
        }
        if self.defaultTextStyle.strikethrough {
            styled = self.theme.strikethrough(styled);
        }
        if self.defaultTextStyle.underline {
            styled = self.theme.underline(styled);
        }
        sentinelIndex = (-1 if sentinel not in styled else styled.index(sentinel));
        self.defaultStylePrefix = (styled[0:sentinelIndex] if (sentinelIndex >= 0) else "");
        return self.defaultStylePrefix;
    }
    def getStylePrefix(styleFn: any) -> str {
        sentinel: str = "\u0000";
        styled = styleFn(sentinel);
        sentinelIndex = (-1 if sentinel not in styled else styled.index(sentinel));
        return (styled[0:sentinelIndex] if (sentinelIndex >= 0) else "");
    }
    def getDefaultInlineStyleContext() -> any {
        return {"applyText": lambda (text: str) -> any { return self.applyDefaultStyle(text); }, "stylePrefix": self.getDefaultStylePrefix()};
    }
    def renderToken(token: any, width: float, nextTokenType: str | None = None, styleContext: any | None = None) -> list[str] {
        lines: list[str] = [];
        _sw = token.type;
        if (_sw == "heading") {
            headingLevel = token.depth;
            headingPrefix: str = f"{("#" * int(headingLevel))} ";
            headingStyleFn: any;
            if (headingLevel == 1) {
                headingStyleFn = lambda (text: str) -> any { return self.theme.heading(self.theme.bold(self.theme.underline(text))); };
            }
            else {
                headingStyleFn = lambda (text: str) -> any { return self.theme.heading(self.theme.bold(text)); };
            }
            headingStyleContext: any = {"applyText": headingStyleFn, "stylePrefix": self.getStylePrefix(headingStyleFn)};
            headingText = self.renderInlineTokens((token.tokens or []), headingStyleContext);
            styledHeading = ((headingStyleFn(headingPrefix) + headingText) if (headingLevel >= 3) else headingText);
            lines.append(styledHeading);
            if (nextTokenType and (nextTokenType != "space")) {
                lines.append("");
            }
            break;
        }
        elif (_sw == "paragraph") {
            paragraphText = self.renderInlineTokens((token.tokens or []), styleContext);
            lines.append(paragraphText);
            if ((nextTokenType and (nextTokenType != "list")) and (nextTokenType != "space")) {
                lines.append("");
            }
            break;
        }
        elif (_sw == "text") {
            lines.append(self.renderInlineTokens([token], styleContext));
        }
        elif (_sw == "code") {
            indent = ((lambda (_jx_null10: any) -> any { return (_jx_null10 if _jx_null10 is not None else "  "); })(self.theme.codeBlockIndent));
            lines.append(self.theme.codeBlockBorder(f"\\`\\`\\`{(token.lang or "")}"));
            if self.theme.highlightCode {
                highlightedLines = self.theme.highlightCode(token.text, token.lang);
                for hlLine in highlightedLines {
                    lines.append(f"{indent}{hlLine}");
                }
            }
            else {
                codeLines = token.text.split("\n");
                for codeLine in codeLines {
                    lines.append(f"{indent}{self.theme.codeBlock(codeLine)}");
                }
            }
            lines.append(self.theme.codeBlockBorder("```"));
            if (nextTokenType and (nextTokenType != "space")) {
                lines.append("");
            }
            break;
        }
        elif (_sw == "list") {
            listLines = self.renderList(token, 0, width, styleContext);
            lines.extend(listLines);
            break;
        }
        elif (_sw == "table") {
            tableLines = self.renderTable(token, width, nextTokenType, styleContext);
            lines.extend(tableLines);
            break;
        }
        elif (_sw == "blockquote") {
            quoteStyle = lambda (text: str) -> any { return self.theme.quote(self.theme.italic(text)); };
            quoteStylePrefix = self.getStylePrefix(quoteStyle);
            applyQuoteStyle = lambda (line: str) -> any { if not quoteStylePrefix {     return quoteStyle(line); } lineWithReappliedStyle = sub(r"\x1b\[0m", f"\\x1b[0m{quoteStylePrefix}", line); return quoteStyle(lineWithReappliedStyle); };
            quoteContentWidth = max(float(1), float((width - 2)));
            quoteInlineStyleContext: any = {"applyText": lambda (text: str) -> any { return text; }, "stylePrefix": quoteStylePrefix};
            quoteTokens = (token.tokens or []);
            renderedQuoteLines: list[str] = [];
            i: int = 0;
            while (i < len(quoteTokens)) {
                quoteToken = quoteTokens[i];
                nextQuoteToken = quoteTokens[(i + 1)];
                renderedQuoteLines.extend(self.renderToken(quoteToken, quoteContentWidth, ((lambda (_jx_opt11: any) -> any { return (_jx_opt11.type if _jx_opt11 is not None else None); })(nextQuoteToken)), quoteInlineStyleContext));
                i += 1;
            }
            while ((len(renderedQuoteLines) > 0) and (renderedQuoteLines[(len(renderedQuoteLines) - 1)] == "")) {
                renderedQuoteLines.pop();
            }
            for quoteLine in renderedQuoteLines {
                styledLine = applyQuoteStyle(quoteLine);
                wrappedLines = wrapTextWithAnsi(styledLine, quoteContentWidth);
                for wrappedLine in wrappedLines {
                    lines.append((self.theme.quoteBorder("│ ") + wrappedLine));
                }
            }
            if (nextTokenType and (nextTokenType != "space")) {
                lines.append("");
            }
            break;
        }
        elif (_sw == "hr") {
            lines.append(self.theme.hr(("─" * int(min(float(width), float(80))))));
            if (nextTokenType and (nextTokenType != "space")) {
                lines.append("");
            }
        }
        elif (_sw == "html") {
            if (("raw" in token) and isinstance(token.raw, str)) {
                lines.append(self.applyDefaultStyle(token.raw.strip()));
            }
        }
        elif (_sw == "space") {
            lines.append("");
        }
        else {
            if (("text" in token) and isinstance(token.text, str)) {
                lines.append(token.text);
            }
        }
        return lines;
    }
    def renderInlineTokens(tokens: list[any], styleContext: any | None = None) -> str {
        result: str = "";
        resolvedStyleContext = ((lambda (_jx_null12: any) -> any { return (_jx_null12 if _jx_null12 is not None else self.getDefaultInlineStyleContext()); })(styleContext));
        _jx_d0: any = resolvedStyleContext;
        applyText = _jx_d0.applyText;
        stylePrefix = _jx_d0.stylePrefix;
        applyTextWithNewlines = lambda (text: str) -> any { segments: list[str] = text.split("\n"); return "\n".join([applyText(segment) for segment in segments]); };
        for token in tokens {
            _sw = token.type;
            if (_sw == "escape") {
                result += applyTextWithNewlines((token.raw if self.options.preserveBackslashEscapes else token.text));
            }
            elif (_sw == "text") {
                if (token.tokens and (len(token.tokens) > 0)) {
                    result += self.renderInlineTokens(token.tokens, resolvedStyleContext);
                }
                else {
                    result += applyTextWithNewlines(token.text);
                }
            }
            elif (_sw == "paragraph") {
                result += self.renderInlineTokens((token.tokens or []), resolvedStyleContext);
            }
            elif (_sw == "strong") {
                boldContent = self.renderInlineTokens((token.tokens or []), resolvedStyleContext);
                result += (self.theme.bold(boldContent) + stylePrefix);
                break;
            }
            elif (_sw == "em") {
                italicContent = self.renderInlineTokens((token.tokens or []), resolvedStyleContext);
                result += (self.theme.italic(italicContent) + stylePrefix);
                break;
            }
            elif (_sw == "codespan") {
                result += (self.theme.code(token.text) + stylePrefix);
            }
            elif (_sw == "link") {
                linkText = self.renderInlineTokens((token.tokens or []), resolvedStyleContext);
                styledLink = self.theme.link(self.theme.underline(linkText));
                if getCapabilities().hyperlinks {
                    result += (hyperlink(styledLink, token.href) + stylePrefix);
                }
                else {
                    hrefForComparison = (token.href[7:] if token.href.startswith("mailto:") else token.href);
                    if ((token.text == token.href) or (token.text == hrefForComparison)) {
                        result += (styledLink + stylePrefix);
                    }
                    else {
                        result += ((styledLink + self.theme.linkUrl(f" ({token.href})")) + stylePrefix);
                    }
                }
                break;
            }
            elif (_sw == "br") {
                result += "\n";
            }
            elif (_sw == "del") {
                delContent = self.renderInlineTokens((token.tokens or []), resolvedStyleContext);
                result += (self.theme.strikethrough(delContent) + stylePrefix);
                break;
            }
            elif (_sw == "html") {
                if (("raw" in token) and isinstance(token.raw, str)) {
                    result += applyTextWithNewlines(token.raw);
                }
            }
            else {
                if (("text" in token) and isinstance(token.text, str)) {
                    result += applyTextWithNewlines(token.text);
                }
            }
        }
        while (stylePrefix and result.endswith(stylePrefix)) {
            result = result[0:-len(stylePrefix)];
        }
        return result;
    }
    def getOrderedListMarker(item: any) -> str | None {
        match_j = compile(r"^(?: {0,3})(\d{1,9}[.)])[ \t]+").exec(item.raw);
        return (f"{match_j[1]} " if match_j else None);
    }
    def getUnorderedListMarker(item: any) -> str | None {
        match_j = compile(r"^(?: {0,3})([-+*])(?:[ \t]+|(?=\r?\n|$))").exec(item.raw);
        return (f"{match_j[1]} " if match_j else None);
    }
    def renderList(token: any, depth: float, width: float, styleContext: any | None = None) -> list[str] {
        lines: list[str] = [];
        indent = ("    " * int(depth));
        startNumber = (token.start if isinstance(token.start, (int, float)) else 1);
        i: int = 0;
        while (i < len(token.items)) {
            item = token.items[i];
            isLastItem = (i == (len(token.items) - 1));
            bullet = ((((lambda (_jx_null13: any) -> any { return (_jx_null13 if _jx_null13 is not None else f"{(startNumber + i)}. "); })(self.getOrderedListMarker(item))) if self.options.preserveOrderedListMarkers else f"{(startNumber + i)}. ") if token.ordered else (((lambda (_jx_null14: any) -> any { return (_jx_null14 if _jx_null14 is not None else "- "); })(self.getUnorderedListMarker(item))) if self.options.preserveOrderedListMarkers else "- "));
            taskMarker = (f"[{("x" if item.checked else " ")}] " if item.task else "");
            marker = (bullet + taskMarker);
            firstPrefix = (indent + self.theme.listBullet(marker));
            continuationPrefix = (indent + (" " * int(visibleWidth(marker))));
            itemWidth = max(float(1), float((width - visibleWidth(firstPrefix))));
            renderedAnyLine: bool = False;
            for itemToken in item.tokens {
                if (itemToken.type == "list") {
                    lines.extend(self.renderList(itemToken, (depth + 1), width, styleContext));
                    renderedAnyLine = True;
                    continue;
                }
                itemLines = self.renderToken(itemToken, itemWidth, None, styleContext);
                for line in itemLines {
                    for wrappedLine in wrapTextWithAnsi(line, itemWidth) {
                        linePrefix = (continuationPrefix if renderedAnyLine else firstPrefix);
                        lines.append((linePrefix + wrappedLine));
                        renderedAnyLine = True;
                    }
                }
            }
            if not renderedAnyLine {
                lines.append(firstPrefix);
            }
            if (token.loose and not isLastItem) {
                lines.append("");
            }
            i += 1;
        }
        return lines;
    }
    def getLongestWordWidth(text: str, maxWidth: float | None = None) -> float {
        words = [word for word in split(r"\s+", text) if (len(word) > 0)];
        longest: float = float(0);
        for word in words {
            longest = max(float(longest), float(visibleWidth(word)));
        }
        if (maxWidth == None) {
            return longest;
        }
        return min(float(longest), float(maxWidth));
    }
    def wrapCellText(text: str, maxWidth: float) -> list[str] {
        return wrapTextWithAnsi(text, max(float(1), float(maxWidth)));
    }
    def renderTable(token: any, availableWidth: float, nextTokenType: str | None = None, styleContext: any | None = None) -> list[str] {
        lines: list[str] = [];
        numCols = len(token.header);
        if (numCols == 0) {
            return lines;
        }
        borderOverhead = ((3 * numCols) + 1);
        availableForCells = (availableWidth - borderOverhead);
        if (availableForCells < numCols) {
            fallbackLines = (wrapTextWithAnsi(token.raw, availableWidth) if token.raw else []);
            if (nextTokenType and (nextTokenType != "space")) {
                fallbackLines.append("");
            }
            return fallbackLines;
        }
        maxUnbrokenWordWidth = 30;
        naturalWidths: list[float] = [];
        minWordWidths: list[float] = [];
        i: int = 0;
        while (i < numCols) {
            headerText = self.renderInlineTokens((token.header[i].tokens or []), styleContext);
            naturalWidths[i] = visibleWidth(headerText);
            minWordWidths[i] = max(float(1), float(self.getLongestWordWidth(headerText, maxUnbrokenWordWidth)));
            i += 1;
        }
        for row in token.rows {
            i: int = 0;
            while (i < len(row)) {
                cellText = self.renderInlineTokens((row[i].tokens or []), styleContext);
                naturalWidths[i] = max(float((naturalWidths[i] or 0)), float(visibleWidth(cellText)));
                minWordWidths[i] = max(float((minWordWidths[i] or 1)), float(self.getLongestWordWidth(cellText, maxUnbrokenWordWidth)));
                i += 1;
            }
        }
        minColumnWidths = minWordWidths;
        minCellsWidth = minColumnWidths.reduce(lambda (a: any, b: any) -> any { return (a + b); }, 0);
        if (minCellsWidth > availableForCells) {
            minColumnWidths = Array(numCols).fill(1);
            remaining = (availableForCells - numCols);
            if (remaining > 0) {
                totalWeight = minWordWidths.reduce(lambda (total: any, width: any) -> any { return (total + max(float(0), float((width - 1)))); }, 0);
                growth = minWordWidths.map(lambda (width: any) -> any { weight = max(float(0), float((width - 1))); return (int((((weight / totalWeight) * remaining)) // 1) if (totalWeight > 0) else 0); });
                i: int = 0;
                while (i < numCols) {
                    minColumnWidths[i] += ((lambda (_jx_null15: any) -> any { return (_jx_null15 if _jx_null15 is not None else 0); })(growth[i]));
                    i += 1;
                }
                allocated = growth.reduce(lambda (total: any, width: any) -> any { return (total + width); }, 0);
                leftover = (remaining - allocated);
                i: int = 0;
                while ((leftover > 0) and (i < numCols)) {
                    minColumnWidths[i] += 1;
                    leftover += -1;
                    i += 1;
                }
            }
            minCellsWidth = minColumnWidths.reduce(lambda (a: any, b: any) -> any { return (a + b); }, 0);
        }
        totalNaturalWidth = (naturalWidths.reduce(lambda (a: any, b: any) -> any { return (a + b); }, 0) + borderOverhead);
        columnWidths: list[float];
        if (totalNaturalWidth <= availableWidth) {
            columnWidths = naturalWidths.map(lambda (width: any, index: any) -> any { return max(float(width), float(minColumnWidths[index])); });
        }
        else {
            totalGrowPotential = naturalWidths.reduce(lambda (total: any, width: any, index: any) -> any { return (total + max(float(0), float((width - minColumnWidths[index])))); }, 0);
            extraWidth = max(float(0), float((availableForCells - minCellsWidth)));
            columnWidths = minColumnWidths.map(lambda (minWidth: any, index: any) -> any { naturalWidth = naturalWidths[index]; minWidthDelta = max(float(0), float((naturalWidth - minWidth))); grow: float = float(0); if (totalGrowPotential > 0) {     grow = int((((minWidthDelta / totalGrowPotential) * extraWidth)) // 1); } return (minWidth + grow); });
            allocated = columnWidths.reduce(lambda (a: any, b: any) -> any { return (a + b); }, 0);
            remaining = (availableForCells - allocated);
            while (remaining > 0) {
                grew: bool = False;
                i: int = 0;
                while ((i < numCols) and (remaining > 0)) {
                    if (columnWidths[i] < naturalWidths[i]) {
                        columnWidths[i] += 1;
                        remaining += -1;
                        grew = True;
                    }
                    i += 1;
                }
                if not grew {
                    break;
                }
            }
        }
        topBorderCells = [("─" * int(w)) for w in columnWidths];
        lines.append(f"┌─{"─┬─".join(topBorderCells)}─┐");
        headerCellLines: list[list[str]] = token.header.map(lambda (cell: any, i: any) -> any { text = self.renderInlineTokens((cell.tokens or []), styleContext); return self.wrapCellText(text, columnWidths[i]); });
        headerLineCount = max(*[float(_jx_math) for _jx_math in [len(c) for c in headerCellLines]]);
        lineIdx: int = 0;
        while (lineIdx < headerLineCount) {
            rowParts = headerCellLines.map(lambda (cellLines: any, colIdx: any) -> any { text = (cellLines[lineIdx] or ""); padded = (text + (" " * int(max(float(0), float((columnWidths[colIdx] - visibleWidth(text))))))); return self.theme.bold(padded); });
            lines.append(f"│ {" │ ".join(rowParts)} │");
            lineIdx += 1;
        }
        separatorCells = [("─" * int(w)) for w in columnWidths];
        separatorLine: str = f"├─{"─┼─".join(separatorCells)}─┤";
        lines.append(separatorLine);
        rowIndex: int = 0;
        while (rowIndex < len(token.rows)) {
            row = token.rows[rowIndex];
            rowCellLines: list[list[str]] = row.map(lambda (cell: any, i: any) -> any { text = self.renderInlineTokens((cell.tokens or []), styleContext); return self.wrapCellText(text, columnWidths[i]); });
            rowLineCount = max(*[float(_jx_math) for _jx_math in [len(c) for c in rowCellLines]]);
            lineIdx: int = 0;
            while (lineIdx < rowLineCount) {
                rowParts = rowCellLines.map(lambda (cellLines: any, colIdx: any) -> any { text = (cellLines[lineIdx] or ""); return (text + (" " * int(max(float(0), float((columnWidths[colIdx] - visibleWidth(text))))))); });
                lines.append(f"│ {" │ ".join(rowParts)} │");
                lineIdx += 1;
            }
            if (rowIndex < (len(token.rows) - 1)) {
                lines.append(separatorLine);
            }
            rowIndex += 1;
        }
        bottomBorderCells = [("─" * int(w)) for w in columnWidths];
        lines.append(f"└─{"─┴─".join(bottomBorderCells)}─┘");
        if (nextTokenType and (nextTokenType != "space")) {
            lines.append("");
        }
        return lines;
    }
}

with entry {
    markdownParser.setOptions({"tokenizer": StrictStrikethroughTokenizer()});
}
