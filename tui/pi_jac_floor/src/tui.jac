# interop import: node:fs { fs }
# interop import: node:os { os }
# interop import: node:path { path }
# interop import: node:perf_hooks { performance }
import from "./keys.jac" { isKeyRelease, matchesKey }
import from "./terminal-colors.jac" { isOsc11BackgroundColorResponse, parseOsc11BackgroundColor, parseTerminalColorSchemeReport }
import from "./terminal-image.jac" { deleteKittyImage, getCapabilities, isImageLine, setCellDimensions }
import from "./utils.jac" { extractSegments, normalizeTerminalOutput, sliceByColumn, sliceWithWidth, visibleWidth }
import from re { search }
import from os { environ }

glob KITTY_SEQUENCE_PREFIX = "\u001b_G";

def parseKittyImageHeader(line: str) -> any | None {
    sequenceStart = (-1 if KITTY_SEQUENCE_PREFIX not in line else line.index(KITTY_SEQUENCE_PREFIX));
    if (sequenceStart == -1) {
        return None;
    }
    paramsStart = (sequenceStart + len(KITTY_SEQUENCE_PREFIX));
    paramsEnd = line.indexOf(";", paramsStart);
    if (paramsEnd == -1) {
        return None;
    }
    ids: list[float] = [];
    rows = 1;
    params = line[paramsStart:paramsEnd];
    for param in params.split(",") {
        _jx_d0: any = param.split("=", 2);
        key = _jx_d0[0];
        value = _jx_d0[1];
        if (value == None) {
            continue;
        }
        numberValue = Number(value);
        if ((not Number.isInteger(numberValue) or (numberValue <= 0)) or (numberValue > 4294967295)) {
            continue;
        }
        if (key == "i") {
            ids.append(numberValue);
        }
        elif (key == "r") {
            rows = numberValue;
        }
    }
    return {"ids": ids, "rows": rows};
}

glob:pub CURSOR_MARKER = "\u001b_pi:c\u0007";

def parseSizeValue(value: any | None, referenceSize: float) -> float | None {
    if (value == None) {
        return None;
    }
    if isinstance(value, (int, float)) {
        return value;
    }
    match_j = search(r"^(\d+(?:\.\d+)?)%$", value);
    if match_j {
        return int((((referenceSize * float(match_j.group(1))) / 100)) // 1);
    }
    return None;
}

def isTermuxSession() -> bool {
    return Boolean(environ.get("TERMUX_VERSION"));
}

obj:pub Container {
    has children: list[any] = [];
    def addChild(component: any) -> None {
        self.children.append(component);
    }
    def removeChild(component: any) -> None {
        index = (-1 if component not in self.children else self.children.index(component));
        if (index != -1) {
            del self.children[index];
        }
    }
    def clear() -> None {
        self.children = [];
    }
    def invalidate() -> None {
        for child in self.children {
            (child.invalidate() if child.invalidate is not None else None);
        }
    }
    def render(width: float) -> list[str] {
        lines: list[str] = [];
        for child in self.children {
            childLines = child.render(width);
            for line in childLines {
                lines.append(line);
            }
        }
        return lines;
    }
}

# ===== JS2JAC UNCONVERTED (3 decl(s), needs LLM) =====
# JS2JAC-HOLE[E7200] Declaration produced no output:
# | function extractKittyImageIds(line: string): number[] {
# | 	return parseKittyImageHeader(line)?.ids ?? [];
# | }

# JS2JAC-HOLE[E7200] Declaration produced no output:
# | function extractKittyImageRows(line: string): number {
# | 	return parseKittyImageHeader(line)?.rows ?? 1;
# | }

# JS2JAC-HOLE[E7200] Declaration produced no output:
# | export function isFocusable(component: Component | null): component is Component & Focusable {
# | 	return component !== null && "focused" in component;
# | }
