import from "../utils.jac" { applyBackgroundToLine, visibleWidth }

obj:pub Box {
    has paddingX: float;
    has paddingY: float;
    has bgFn: any | None = None;
    has cache: any | None = None;
    has children: list[any] = [];
    def __init__(paddingX: float = 1, paddingY: float = 1, bgFn: any | None = None) -> None {
        self.paddingX = paddingX;
        self.paddingY = paddingY;
        self.bgFn = bgFn;
    }
    def addChild(component: any) -> None {
        self.children.append(component);
        self.invalidateCache();
    }
    def removeChild(component: any) -> None {
        index = (-1 if component not in self.children else self.children.index(component));
        if (index != -1) {
            del self.children[index];
            self.invalidateCache();
        }
    }
    def clear() -> None {
        self.children = [];
        self.invalidateCache();
    }
    def setBgFn(bgFn: any | None = None) -> None {
        self.bgFn = bgFn;
    }
    def invalidateCache() -> None {
        self.cache = None;
    }
    def matchCache(width: float, childLines: list[str], bgSample: str | None) -> bool {
        cache = self.cache;
        return ((((not not cache and (cache.width == width)) and (cache.bgSample == bgSample)) and (len(cache.childLines) == len(childLines))) and cache.childLines.every(lambda (line: any, i: any) -> any { return (line == childLines[i]); }));
    }
    def invalidate() -> None {
        self.invalidateCache();
        for child in self.children {
            ((lambda (_jx_opt0: any) -> any { return (_jx_opt0() if _jx_opt0 is not None else None); })(child.invalidate));
        }
    }
    def render(width: float) -> list[str] {
        if (len(self.children) == 0) {
            return [];
        }
        contentWidth = max(float(1), float((width - (self.paddingX * 2))));
        leftPad = (" " * int(self.paddingX));
        childLines: list[str] = [];
        for child in self.children {
            lines = child.render(contentWidth);
            for line in lines {
                childLines.append((leftPad + line));
            }
        }
        if (len(childLines) == 0) {
            return [];
        }
        bgSample = (self.bgFn("test") if self.bgFn else None);
        if self.matchCache(width, childLines, bgSample) {
            return (self.cache as any).lines;
        }
        result: list[str] = [];
        i: int = 0;
        while (i < self.paddingY) {
            result.append(self.applyBg("", width));
            i += 1;
        }
        for line in childLines {
            result.append(self.applyBg(line, width));
        }
        i: int = 0;
        while (i < self.paddingY) {
            result.append(self.applyBg("", width));
            i += 1;
        }
        self.cache = {"childLines": childLines, "width": width, "bgSample": bgSample, "lines": result};
        return result;
    }
    def applyBg(line: str, width: float) -> str {
        visLen = visibleWidth(line);
        padNeeded = max(float(0), float((width - visLen)));
        padded = (line + (" " * int(padNeeded)));
        if self.bgFn {
            return applyBackgroundToLine(padded, width, self.bgFn);
        }
        return padded;
    }
}
