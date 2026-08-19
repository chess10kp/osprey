import from "../utils.jac" { truncateToWidth, visibleWidth }

obj:pub TruncatedText {
    has text: str;
    has paddingX: float;
    has paddingY: float;
    def __init__(text: str, paddingX: float = 0, paddingY: float = 0) -> None {
        self.text = text;
        self.paddingX = paddingX;
        self.paddingY = paddingY;
    }
    def invalidate() -> None {
    }
    def render(width: float) -> list[str] {
        result: list[str] = [];
        emptyLine = (" " * int(width));
        i: int = 0;
        while (i < self.paddingY) {
            result.append(emptyLine);
            i += 1;
        }
        availableWidth = max(float(1), float((width - (self.paddingX * 2))));
        singleLineText = self.text;
        newlineIndex = (-1 if "\n" not in self.text else self.text.index("\n"));
        if (newlineIndex != -1) {
            singleLineText = self.text[0:newlineIndex];
        }
        displayText = truncateToWidth(singleLineText, availableWidth);
        leftPadding = (" " * int(self.paddingX));
        rightPadding = (" " * int(self.paddingX));
        lineWithPadding = ((leftPadding + displayText) + rightPadding);
        lineVisibleWidth = visibleWidth(lineWithPadding);
        paddingNeeded = max(float(0), float((width - lineVisibleWidth)));
        finalLine = (lineWithPadding + (" " * int(paddingNeeded)));
        result.append(finalLine);
        i: int = 0;
        while (i < self.paddingY) {
            result.append(emptyLine);
            i += 1;
        }
        return result;
    }
}
