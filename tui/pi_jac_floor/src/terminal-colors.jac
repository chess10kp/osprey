import from re { compile, search, sub, I }

def hexToRgb(hex: str) -> any {
    normalized = (hex[1:] if hex.startswith("#") else hex);
    r = int(normalized[0:2], 16);
    g = int(normalized[2:4], 16);
    b = int(normalized[4:6], 16);
    return {"r": r, "g": g, "b": b};
}

def parseOscHexChannel(channel: str) -> float | None {
    if not (search(r"^[0-9a-f]+$", channel, I as int) is not None) {
        return None;
    }
    max_j = ((16 ** len(channel)) - 1);
    if (max_j <= 0) {
        return None;
    }
    return round(((int(channel, 16) / max_j) * 255) as float);
}

glob OSC11_BACKGROUND_COLOR_RESPONSE_PATTERN = compile(r"^\x1b\]11;([^\x07\x1b]*)(?:\x07|\x1b\\)$", I as int);

glob COLOR_SCHEME_REPORT_PATTERN = compile(r"^\x1b\[\?997;(1|2)n$");

def:pub isOsc11BackgroundColorResponse(data: str) -> bool {
    return (search(OSC11_BACKGROUND_COLOR_RESPONSE_PATTERN, data) is not None);
}

def:pub parseOsc11BackgroundColor(data: str) -> any | None {
    match_j = search(OSC11_BACKGROUND_COLOR_RESPONSE_PATTERN, data);
    if not match_j {
        return None;
    }
    value: str = match_j[1].strip();
    if value.startswith("#") {
        hex = value[1:];
        if (search(r"^[0-9a-f]{6}$", hex, I as int) is not None) {
            return hexToRgb(value);
        }
        if (search(r"^[0-9a-f]{12}$", hex, I as int) is not None) {
            r = parseOscHexChannel(hex[0:4]);
            g = parseOscHexChannel(hex[4:8]);
            b = parseOscHexChannel(hex[8:12]);
            return ({"r": r, "g": g, "b": b} if (((r != None) and (g != None)) and (b != None)) else None);
        }
        return None;
    }
    rgbValue = sub(r"^rgba?:", "", value, I as int);
    _jx_d0: any = rgbValue.split("/");
    red = _jx_d0[0];
    green = _jx_d0[1];
    blue = _jx_d0[2];
    if (((red == None) or (green == None)) or (blue == None)) {
        return None;
    }
    r = parseOscHexChannel(red);
    g = parseOscHexChannel(green);
    b = parseOscHexChannel(blue);
    return ({"r": r, "g": g, "b": b} if (((r != None) and (g != None)) and (b != None)) else None);
}

def:pub parseTerminalColorSchemeReport(data: str) -> any | None {
    match_j = search(COLOR_SCHEME_REPORT_PATTERN, data);
    if not match_j {
        return None;
    }
    return ("light" if (match_j[1] == "2") else "dark");
}
