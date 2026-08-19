obj:pub Spacer {
    has lines: float;
    def __init__(lines: float = 1) -> None {
        self.lines = lines;
    }
    def setLines(lines: float) -> None {
        self.lines = lines;
    }
    def invalidate() -> None {
    }
    def render(_width: float) -> list[str] {
        result: list[str] = [];
        i: int = 0;
        while (i < self.lines) {
            result.append("");
            i += 1;
        }
        return result;
    }
}
