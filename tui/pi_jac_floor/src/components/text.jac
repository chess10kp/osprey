import from ..utils { applyBackgroundToLine, visibleWidth, wrapTextWithAnsi }

obj:pub Text {
    has text: str;
    has paddingX: float;
    has paddingY: float;
    has customBgFn: any | None = None;
    has cachedText: str | None = None;
    has cachedWidth: float | None = None;
    has cachedLines: list[str] | None = None;
    def __init__(text: str = "", paddingX: float = 1, paddingY: float = 1, customBgFn: any | None = None) -> None {
        self.text = text;
        self.paddingX = paddingX;
        self.paddingY = paddingY;
        self.customBgFn = customBgFn;
    }
    def setText(text: str) -> None {
        self.text = text;
        self.cachedText = None;
        self.cachedWidth = None;
        self.cachedLines = None;
    }
    def setCustomBgFn(customBgFn: any | None = None) -> None {
        self.customBgFn = customBgFn;
        self.cachedText = None;
        self.cachedWidth = None;
        self.cachedLines = None;
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
        if (not self.text or (self.text.strip() == "")) {
            result: list[str] = [];
            self.cachedText = self.text;
            self.cachedWidth = width;
            self.cachedLines = result;
            return result;
        }
        normalizedText = self.text.replace("\t", "   ");
        contentWidth = max(float(1), float((width - (self.paddingX * 2))));
        wrappedLines = wrapTextWithAnsi(normalizedText, contentWidth);
        leftMargin = (" " * int(self.paddingX));
        rightMargin = (" " * int(self.paddingX));
        contentLines: list[str] = [];
        for line in wrappedLines {
            lineWithMargins = ((leftMargin + line) + rightMargin);
            if self.customBgFn {
                contentLines.append(applyBackgroundToLine(lineWithMargins, width, self.customBgFn));
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
            line = (applyBackgroundToLine(emptyLine, width, self.customBgFn) if self.customBgFn else emptyLine);
            emptyLines.append(line);
            i += 1;
        }
        result = [*emptyLines, *contentLines, *emptyLines];
        self.cachedText = self.text;
        self.cachedWidth = width;
        self.cachedLines = result;
        return (result if (len(result) > 0) else [""]);
    }
}
