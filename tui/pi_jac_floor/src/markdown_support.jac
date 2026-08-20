"""Jac-native runtime adapter reproducing the slice of the `marked` npm
package that the ported `markdown.ts` -> `markdown.jac` component depends on.

The js2jac conversion left a dead interop comment (`# interop import: marked
{ Marked, Tokenizer }`) in `components/markdown.jac` -- `marked` is a JS
library with no Python/Jac equivalent, so `Marked()`/`Tokenizer` resolved to
undefined names at runtime (only a W2001 "may be undefined" warning, not a
`jac check` error, since both are used through `any`-typed call sites).

This module re-implements just enough of marked's block + inline lexer to
drive `Markdown.render()`: headings, paragraphs, fenced code blocks, ordered/
unordered/task lists (with nesting), blockquotes, tables, thematic breaks,
blank-line "space" tokens, and inline text/strong/em/codespan/link/br/del,
plus the `Tokenizer.del` override hook `StrictStrikethroughTokenizer` in
markdown.jac relies on for `~~strikethrough~~`.

Token shape: `Tok` wraps a dict and exposes both attribute access (`tok.type`,
matching marked's `Token` objects) and `in`/`isinstance(tok.x, str)` dict-like
checks the ported component performs (`"raw" in token`) -- so the converted
call sites in markdown.jac work unmodified against these tokens, the same way
a real JS `Token` object would.
"""

import re;

obj Tok {
    has d: dict = {};
    def __init__(d: dict = {}) -> None {
        self.d = d;
    }
    def __getattr__(name: str) -> any {
        return self.d.get(name);
    }
    def __setattr__(name: str, value: any) -> None {
        if (name == "d") {
            object.__setattr__(self, "d", value);
        } else {
            self.d[name] = value;
        }
    }
    def __contains__(name: str) -> bool {
        return name in self.d;
    }
    def __repr__() -> str {
        return f"Tok({self.d!r})";
    }
}

obj:pub Tokenizer {
    has lexer: any = None;
    def del(src: str) -> any | None {
        return None;
    }
}

glob HEADING_RE = re.compile(r"^ {0,3}(#{1,6})(?:\s+(.*?))?\s*$");
glob HR_RE = re.compile(r"^ {0,3}((?:-[ \t]*){3,}|(?:\*[ \t]*){3,}|(?:_[ \t]*){3,})$");
glob FENCE_RE = re.compile(r"^ {0,3}(`{3,}|~{3,})\s*(\S*)\s*$");
glob BLOCKQUOTE_RE = re.compile(r"^ {0,3}>[ \t]?(.*)$");
glob BULLET_RE = re.compile(r"^( {0,3})([-+*])([ \t]+|$)(.*)$");
glob ORDERED_RE = re.compile(r"^( {0,3})(\d{1,9})([.)])([ \t]+|$)(.*)$");
glob TASK_RE = re.compile(r"^\[([ xX])\][ \t]+(.*)$");
glob TABLE_SEP_RE = re.compile(r"^\s*\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)+\|?\s*$");

def isBlockStart(line: str) -> bool {
    if line.strip() == "" {
        return True;
    }
    if HEADING_RE.match(line) {
        return True;
    }
    if HR_RE.match(line) {
        return True;
    }
    if FENCE_RE.match(line) {
        return True;
    }
    if BLOCKQUOTE_RE.match(line) {
        return True;
    }
    if BULLET_RE.match(line) {
        return True;
    }
    if ORDERED_RE.match(line) {
        return True;
    }
    return False;
}

def blockTokens(src: str, tokenizer: any) -> list[any] {
    lines = src.split("\n");
    n = len(lines);
    tokens: list[any] = [];
    i = 0;
    while i < n {
        line = lines[i];

        if line.strip() == "" {
            j = i;
            while (j < n) and (lines[j].strip() == "") {
                j += 1;
            }
            tokens.append(Tok({"type": "space", "raw": "\n".join(lines[i:j])}));
            i = j;
            continue;
        }

        fenceMatch = FENCE_RE.match(line);
        if fenceMatch {
            fenceChar = fenceMatch.group(1)[0];
            fenceLen = len(fenceMatch.group(1));
            lang = fenceMatch.group(2);
            j = i + 1;
            contentLines: list[str] = [];
            closed = False;
            while j < n {
                closeMatch = re.match(f"^ {{0,3}}({re.escape(fenceChar)}{{{fenceLen},}})\\s*$", lines[j]);
                if closeMatch {
                    closed = True;
                    j += 1;
                    break;
                }
                contentLines.append(lines[j]);
                j += 1;
            }
            raw = "\n".join(lines[i:j]);
            tokens.append(Tok({"type": "code", "raw": raw, "lang": lang, "text": "\n".join(contentLines)}));
            i = j;
            continue;
        }

        headingMatch = HEADING_RE.match(line);
        if headingMatch and (headingMatch.group(2) is not None) and (headingMatch.group(2) != "") {
            depth = len(headingMatch.group(1));
            text: str = headingMatch.group(2).strip();
            text = re.sub(r"\s+#+\s*$", "", text);
            tokens.append(Tok({"type": "heading", "raw": line, "depth": depth, "text": text, "tokens": lexInline(text, tokenizer)}));
            i += 1;
            continue;
        }

        if HR_RE.match(line) {
            tokens.append(Tok({"type": "hr", "raw": line}));
            i += 1;
            continue;
        }

        bqMatch = BLOCKQUOTE_RE.match(line);
        if bqMatch {
            j = i;
            inner: list[str] = [];
            while j < n {
                m = BLOCKQUOTE_RE.match(lines[j]);
                if m {
                    inner.append(m.group(1));
                    j += 1;
                    continue;
                }
                if lines[j].strip() == "" {
                    break;
                }
                if isBlockStart(lines[j]) {
                    break;
                }
                inner.append(lines[j]);
                j += 1;
            }
            innerText = "\n".join(inner);
            tokens.append(Tok({"type": "blockquote", "raw": "\n".join(lines[i:j]), "text": innerText, "tokens": blockTokens(innerText, tokenizer)}));
            i = j;
            continue;
        }

        if (BULLET_RE.match(line) or ORDERED_RE.match(line)) {
            (listTok, j) = parseList(lines, i, n, tokenizer);
            tokens.append(listTok);
            i = j;
            continue;
        }

        if ("|" in line) and (i + 1 < n) and TABLE_SEP_RE.match(lines[(i + 1)]) {
            (tableTok, j) = parseTable(lines, i, n, tokenizer);
            tokens.append(tableTok);
            i = j;
            continue;
        }

        # paragraph: gather consecutive non-blank lines that don't start a new block
        j = i + 1;
        paraLines = [line];
        while j < n {
            nextLine = lines[j];
            if nextLine.strip() == "" {
                break;
            }
            nextHeadingMatch = HEADING_RE.match(nextLine);
            if nextHeadingMatch and (nextHeadingMatch.group(2) is not None) {
                break;
            }
            if HR_RE.match(nextLine) or FENCE_RE.match(nextLine) or BLOCKQUOTE_RE.match(nextLine) {
                break;
            }
            if BULLET_RE.match(nextLine) or ORDERED_RE.match(nextLine) {
                break;
            }
            paraLines.append(nextLine);
            j += 1;
        }
        text: str = joinParagraphLines(paraLines);
        tokens.append(Tok({"type": "paragraph", "raw": "\n".join(paraLines), "text": text, "tokens": lexInline(text, tokenizer)}));
        i = j;
    }
    return tokens;
}

def joinParagraphLines(paraLines: list[str]) -> str {
    parts: list[str] = [];
    k = 0;
    while k < len(paraLines) {
        raw = paraLines[k];
        isLast = (k == (len(paraLines) - 1));
        stripped = raw.rstrip("\n");
        hardBreak = (not isLast) and (stripped.endswith("  ") or stripped.endswith("\\"));
        content = stripped.strip() if k == 0 else stripped.strip();
        parts.append(content);
        if hardBreak and (not isLast) {
            parts.append("\n");
        }
        elif not isLast {
            parts.append(" ");
        }
        k += 1;
    }
    return "".join(parts);
}

def parseList(lines: list[str], start: int, n: int, tokenizer: any) -> tuple {
    firstBullet = BULLET_RE.match(lines[start]);
    ordered = firstBullet is None;
    startNumber = 1;
    if ordered {
        om = ORDERED_RE.match(lines[start]);
        if om {
            startNumber = int(om.group(2));
        }
    }

    firstOrdered = ORDERED_RE.match(lines[start]);
    topIndent = len(firstBullet.group(1)) if firstBullet else (len(firstOrdered.group(1)) if firstOrdered else 0);

    i = start;
    itemBlocks: list[str] = [];
    itemRawFirstLines: list[str] = [];
    hasBlankBetween = False;
    while i < n {
        line = lines[i];
        m = BULLET_RE.match(line) if (not ordered) else ORDERED_RE.match(line);
        if not m {
            break;
        }
        markerIndent = len(m.group(1));
        if markerIndent != topIndent {
            break;
        }
        if not ordered {
            markerWidth = len(m.group(2)) + (len(m.group(3)) if (len(m.group(3)) > 0) else 1);
            firstContent = m.group(4);
        } else {
            markerWidth = len(m.group(2)) + len(m.group(3)) + (len(m.group(4)) if (len(m.group(4)) > 0) else 1);
            firstContent = m.group(5);
        }
        itemRawFirstLines.append(line);
        contIndent = markerIndent + markerWidth;
        itemLines = [firstContent];
        j = i + 1;
        blankRun = 0;
        while j < n {
            candidate = lines[j];
            if candidate.strip() == "" {
                # lookahead: still part of item if next non-blank line is indented enough
                k = j;
                while (k < n) and (lines[k].strip() == "") {
                    k += 1;
                }
                if (k < n) and (len(lines[k]) - len(lines[k].lstrip(" ")) >= contIndent) and (lines[k].strip() != "") {
                    hasBlankBetween = True;
                    itemLines.append("");
                    j += 1;
                    continue;
                }
                break;
            }
            indentLen = len(candidate) - len(candidate.lstrip(" "));
            if indentLen >= contIndent {
                itemLines.append(candidate[contIndent:]);
                j += 1;
                continue;
            }
            # not indented enough: not a continuation of this item
            break;
        }
        itemBlocks.append("\n".join(itemLines));
        i = j;
    }

    loose = hasBlankBetween;
    items: list[any] = [];
    idx = 0;
    while idx < len(itemBlocks) {
        raw = itemRawFirstLines[idx];
        content = itemBlocks[idx];
        task = False;
        checked = False;
        tm = TASK_RE.match(content);
        if tm {
            task = True;
            checked = tm.group(1) != " ";
            content = tm.group(2) + "\n" + "\n".join(content.split("\n")[1:]) if ("\n" in content) else tm.group(2);
        }
        itemTokens = blockTokens(content, tokenizer);
        items.append(Tok({"type": "list_item", "raw": raw, "task": task, "checked": checked, "tokens": itemTokens}));
        idx += 1;
    }

    listTok = Tok({"type": "list", "ordered": ordered, "start": startNumber, "loose": loose, "items": items, "raw": "\n".join(lines[start:i])});
    return (listTok, i);
}

def splitRow(line: str) -> list[str] {
    trimmed = line.strip();
    if trimmed.startswith("|") {
        trimmed = trimmed[1:];
    }
    if trimmed.endswith("|") {
        trimmed = trimmed[0:-1];
    }
    cells: list[str] = [];
    buf = "";
    escaped = False;
    for ch in trimmed {
        if escaped {
            buf += ch;
            escaped = False;
            continue;
        }
        if ch == "\\" {
            buf += ch;
            escaped = True;
            continue;
        }
        if ch == "|" {
            cells.append(buf.strip());
            buf = "";
            continue;
        }
        buf += ch;
    }
    cells.append(buf.strip());
    return cells;
}

def parseTable(lines: list[str], start: int, n: int, tokenizer: any) -> tuple {
    headerCells = splitRow(lines[start]);
    header = [Tok({"text": cell, "tokens": lexInline(cell, tokenizer)}) for cell in headerCells];
    i = start + 2;
    rows: list[any] = [];
    while (i < n) and ("|" in lines[i]) and (lines[i].strip() != "") {
        rowCells = splitRow(lines[i]);
        rows.append([Tok({"text": cell, "tokens": lexInline(cell, tokenizer)}) for cell in rowCells]);
        i += 1;
    }
    raw = "\n".join(lines[start:i]);
    return (Tok({"type": "table", "raw": raw, "header": header, "rows": rows}), i);
}

glob ESCAPABLE_RE = re.compile(r"^\\([!\"#$%&'()*+,\-./:;<=>?@\[\]\\^_`{|}~])");
glob AUTOLINK_RE = re.compile(r"^<((?:https?|mailto):[^\s>]+)>");
glob LINK_RE = re.compile(r"^\[((?:[^\[\]]|\\.)*)\]\(([^()\s]*(?:\([^()]*\)[^()\s]*)*)\)");

def lexInline(text: str, tokenizer: any) -> list[any] {
    tokens: list[any] = [];
    buf = "";
    i = 0;
    n = len(text);

    while i < n {
        rest = text[i:];

        escMatch = ESCAPABLE_RE.match(rest);
        if escMatch {
            if buf != "" {
                tokens.append(Tok({"type": "text", "raw": buf, "text": buf}));
                buf = "";
            }
            tokens.append(Tok({"type": "escape", "raw": escMatch.group(0), "text": escMatch.group(1)}));
            i += len(escMatch.group(0));
            continue;
        }

        if (text[i] == "~") and (tokenizer is not None) {
            delResult = tokenizer.del(rest);
            if delResult is not None {
                if buf != "" {
                    tokens.append(Tok({"type": "text", "raw": buf, "text": buf}));
                    buf = "";
                }
                delDict = delResult if isinstance(delResult, dict) else delResult.d;
                delTok = Tok(delDict);
                tokens.append(delTok);
                i += len(str(delTok.raw));
                continue;
            }
        }

        if text[i] == "`" {
            j = i;
            while (j < n) and (text[j] == "`") {
                j += 1;
            }
            fenceLen = j - i;
            closeIdx = text.find("`" * fenceLen, j);
            if closeIdx != -1 {
                content = text[j:closeIdx];
                if (content.startswith(" ") and content.endswith(" ")) and (content.strip() != "") {
                    content = content[1:-1];
                }
                if buf != "" {
                    tokens.append(Tok({"type": "text", "raw": buf, "text": buf}));
                    buf = "";
                }
                tokens.append(Tok({"type": "codespan", "raw": text[i:(closeIdx + fenceLen)], "text": content}));
                i = closeIdx + fenceLen;
                continue;
            }
        }

        if text[i:(i + 2)] in ("**", "__") {
            delim = text[i:(i + 2)];
            closeIdx = text.find(delim, i + 2);
            if (closeIdx != -1) and (closeIdx > i + 2) {
                inner = text[(i + 2):closeIdx];
                if buf != "" {
                    tokens.append(Tok({"type": "text", "raw": buf, "text": buf}));
                    buf = "";
                }
                tokens.append(Tok({"type": "strong", "raw": text[i:(closeIdx + 2)], "text": inner, "tokens": lexInline(inner, tokenizer)}));
                i = closeIdx + 2;
                continue;
            }
        }

        if text[i] in ("*", "_") {
            c = text[i];
            closeIdx = -1;
            k = i + 1;
            while k < n {
                if (text[k] == c) and (text[(k + 1):(k + 2)] != c) {
                    closeIdx = k;
                    break;
                }
                k += 1;
            }
            if (closeIdx != -1) and (closeIdx > i + 1) {
                inner = text[(i + 1):closeIdx];
                if buf != "" {
                    tokens.append(Tok({"type": "text", "raw": buf, "text": buf}));
                    buf = "";
                }
                tokens.append(Tok({"type": "em", "raw": text[i:(closeIdx + 1)], "text": inner, "tokens": lexInline(inner, tokenizer)}));
                i = closeIdx + 1;
                continue;
            }
        }

        linkMatch = LINK_RE.match(rest);
        if linkMatch {
            linkText = linkMatch.group(1);
            href = linkMatch.group(2);
            if buf != "" {
                tokens.append(Tok({"type": "text", "raw": buf, "text": buf}));
                buf = "";
            }
            tokens.append(Tok({"type": "link", "raw": linkMatch.group(0), "href": href, "text": linkText, "tokens": lexInline(linkText, tokenizer)}));
            i += len(linkMatch.group(0));
            continue;
        }

        autoMatch = AUTOLINK_RE.match(rest);
        if autoMatch {
            url = autoMatch.group(1);
            if buf != "" {
                tokens.append(Tok({"type": "text", "raw": buf, "text": buf}));
                buf = "";
            }
            tokens.append(Tok({"type": "link", "raw": autoMatch.group(0), "href": url, "text": url, "tokens": [Tok({"type": "text", "raw": url, "text": url})]}));
            i += len(autoMatch.group(0));
            continue;
        }

        if (text[i:(i + 2)] == "  ") and ((i + 2) < n) and (text[(i + 2)] == "\n") {
            if buf != "" {
                tokens.append(Tok({"type": "text", "raw": buf, "text": buf}));
                buf = "";
            }
            tokens.append(Tok({"type": "br", "raw": "  \n"}));
            i += 3;
            continue;
        }

        buf += text[i];
        i += 1;
    }
    if buf != "" {
        tokens.append(Tok({"type": "text", "raw": buf, "text": buf}));
        buf = "";
    }
    return tokens;
}

obj:pub Marked {
    has tokenizer: any = None;
    def __init__() -> None {
        self.tokenizer = Tokenizer();
        self.tokenizer.lexer = self;
    }
    def setOptions(options: dict) -> None {
        tok = options.get("tokenizer");
        if tok is not None {
            self.tokenizer = tok;
            self.tokenizer.lexer = self;
        }
    }
    def lexer(text: str) -> list[any] {
        return blockTokens(text, self.tokenizer);
    }
    def inlineTokens(text: str) -> list[any] {
        return lexInline(text, self.tokenizer);
    }
}
