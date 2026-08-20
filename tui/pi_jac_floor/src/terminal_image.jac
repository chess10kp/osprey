import from os { environ }
import from .image_support {
    buffer_from_base64, buffer_from_utf8, to_base64,
    read_uint32_be, read_uint16_be, read_uint16_le, read_uint32_le,
    ascii_decode, random_float, probe_tmux_client_termfeatures
}

glob cachedCapabilities: any | None = None;

glob cellDimensions: any = {"widthPx": 9, "heightPx": 18};

def:pub getCellDimensions() -> any {
    return cellDimensions;
}

def:pub setCellDimensions(dims: any) -> None {
    cellDimensions = dims;
}

def probeTmuxHyperlinks() -> bool {
    try {
        termfeatures = probe_tmux_client_termfeatures();
        if termfeatures is None {
            return False;
        }
        return ("hyperlinks" in [feature.strip() for feature in termfeatures.split(",")]);
    }
    except Exception {
        return False;
    }
}

def _env_lower(key: str) -> str {
    val = environ.get(key);
    return (val.lower() if val is not None else "");
}

def:pub detectCapabilities(tmuxForwardsHyperlink: any = probeTmuxHyperlinks) -> any {
    termProgram = _env_lower("TERM_PROGRAM");
    terminalEmulator = _env_lower("TERMINAL_EMULATOR");
    term = _env_lower("TERM");
    colorTerm = _env_lower("COLORTERM");
    hasTrueColorHint = ((colorTerm == "truecolor") or (colorTerm == "24bit"));
    if (environ.get("TMUX") or term.startswith("tmux")) {
        return {"images": None, "trueColor": hasTrueColorHint, "hyperlinks": tmuxForwardsHyperlink()};
    }
    if term.startswith("screen") {
        return {"images": None, "trueColor": hasTrueColorHint, "hyperlinks": False};
    }
    if (environ.get("KITTY_WINDOW_ID") or (termProgram == "kitty")) {
        return {"images": "kitty", "trueColor": True, "hyperlinks": True};
    }
    if (((termProgram == "ghostty") or ("ghostty" in term)) or environ.get("GHOSTTY_RESOURCES_DIR")) {
        return {"images": "kitty", "trueColor": True, "hyperlinks": True};
    }
    if (environ.get("WEZTERM_PANE") or (termProgram == "wezterm")) {
        return {"images": "kitty", "trueColor": True, "hyperlinks": True};
    }
    if (((termProgram == "warpterminal") or environ.get("WARP_SESSION_ID")) or environ.get("WARP_TERMINAL_SESSION_UUID")) {
        return {"images": "kitty", "trueColor": True, "hyperlinks": True};
    }
    if (environ.get("ITERM_SESSION_ID") or (termProgram == "iterm.app")) {
        return {"images": "iterm2", "trueColor": True, "hyperlinks": True};
    }
    if environ.get("WT_SESSION") {
        return {"images": None, "trueColor": True, "hyperlinks": True};
    }
    if (termProgram == "vscode") {
        return {"images": None, "trueColor": True, "hyperlinks": True};
    }
    if (termProgram == "alacritty") {
        return {"images": None, "trueColor": True, "hyperlinks": True};
    }
    if (terminalEmulator == "jetbrains-jediterm") {
        return {"images": None, "trueColor": True, "hyperlinks": False};
    }
    return {"images": None, "trueColor": hasTrueColorHint, "hyperlinks": False};
}

def:pub getCapabilities() -> any {
    if not cachedCapabilities {
        cachedCapabilities = detectCapabilities();
    }
    return cachedCapabilities;
}

def:pub resetCapabilitiesCache() -> None {
    cachedCapabilities = None;
}

def:pub setCapabilities(caps: any) -> None {
    cachedCapabilities = caps;
}

glob KITTY_PREFIX = "\u001b_G";

glob ITERM2_PREFIX = "\u001b]1337;File=";

# Runtime-crash fix: the js2jac conversion emitted the literal text "\x1b"
# (backslash, x, 1, b) inside f-strings below instead of a real ESC byte --
# harmless to `jac check` (it is still a valid string) but produces garbage
# escape sequences at runtime instead of genuine terminal control codes.
# ESC/ST/BEL below are the real control characters those f-strings need.
glob ESC = "\u001b";
glob ST = "\u001b\\";
glob BEL = "\u0007";

def:pub isImageLine(line: str) -> bool {
    if (line.startswith(KITTY_PREFIX) or line.startswith(ITERM2_PREFIX)) {
        return True;
    }
    return ((KITTY_PREFIX in line) or (ITERM2_PREFIX in line));
}

def:pub allocateImageId() -> float {
    return (int(((random_float() * 4294967294)) // 1) + 1);
}

def:pub encodeKitty(base64Data: str, options: dict[str, float | None | bool | None] = {}) -> str {
    CHUNK_SIZE = 4096;
    params: list[str] = ["a=T", "f=100", "q=2"];
    if (options.get("moveCursor") == False) {
        params.append("C=1");
    }
    if options.get("columns") {
        params.append(f"c={options.get("columns")}");
    }
    if options.get("rows") {
        params.append(f"r={options.get("rows")}");
    }
    if options.get("imageId") {
        params.append(f"i={options.get("imageId")}");
    }
    if (len(base64Data) <= CHUNK_SIZE) {
        return f"{ESC}_G{",".join(params)};{base64Data}{ST}";
    }
    chunks: list[str] = [];
    offset = 0;
    isFirst: bool = True;
    while (offset < len(base64Data)) {
        chunk = base64Data[offset:(offset + CHUNK_SIZE)];
        isLast = ((offset + CHUNK_SIZE) >= len(base64Data));
        if isFirst {
            chunks.append(f"{ESC}_G{",".join(params)},m=1;{chunk}{ST}");
            isFirst = False;
        }
        elif isLast {
            chunks.append(f"{ESC}_Gm=0;{chunk}{ST}");
        }
        else {
            chunks.append(f"{ESC}_Gm=1;{chunk}{ST}");
        }
        offset += CHUNK_SIZE;
    }
    return "".join(chunks);
}

def:pub deleteKittyImage(imageId: float) -> str {
    return f"{ESC}_Ga=d,d=I,i={imageId},q=2{ST}";
}

def:pub deleteAllKittyImages() -> str {
    return "\u001b_Ga=d,d=A,q=2\u001b\\";
}

def:pub encodeITerm2(base64Data: str, options: dict[str, float | str | None | str | None | bool | None] = {}) -> str {
    params: list[str] = [f"inline={(1 if (options.get("inline") != False) else 0)}"];
    if (options.get("width") != None) {
        params.append(f"width={options.get("width")}");
    }
    if (options.get("height") != None) {
        params.append(f"height={options.get("height")}");
    }
    if options.get("name") {
        nameBase64 = to_base64(buffer_from_utf8((options.get("name") as str)));
        params.append(f"name={nameBase64}");
    }
    if (options.get("preserveAspectRatio") == False) {
        params.append("preserveAspectRatio=0");
    }
    return f"{ESC}]1337;File={";".join(params)}:{base64Data}{BEL}";
}

def:pub calculateImageCellSize(imageDimensions: any, maxWidthCells: float, maxHeightCells: float | None, cellDimensions: any = {"widthPx": 9, "heightPx": 18}) -> any {
    maxWidth = max(float(1), float(int((maxWidthCells) // 1)));
    maxHeight = (None if (maxHeightCells == None) else max(float(1), float(int((maxHeightCells) // 1))));
    imageWidth = max(float(1), float(imageDimensions["widthPx"]));
    imageHeight = max(float(1), float(imageDimensions["heightPx"]));
    widthScale = ((maxWidth * cellDimensions["widthPx"]) / imageWidth);
    heightScale = (widthScale if (maxHeight == None) else ((maxHeight * cellDimensions["heightPx"]) / imageHeight));
    scale = min(float(widthScale), float(heightScale));
    scaledWidthPx = (imageWidth * scale);
    scaledHeightPx = (imageHeight * scale);
    columns = int(-((-(scaledWidthPx / cellDimensions["widthPx"])) // 1));
    rows = int(-((-(scaledHeightPx / cellDimensions["heightPx"])) // 1));
    return {"columns": max(float(1), float(min(float(maxWidth), float(columns)))), "rows": max(float(1), float((rows if (maxHeight == None) else min(float(maxHeight), float(rows)))))};
}

def:pub calculateImageRows(imageDimensions: any, targetWidthCells: float, cellDimensions: any = {"widthPx": 9, "heightPx": 18}) -> float {
    return (calculateImageCellSize(imageDimensions, targetWidthCells, None, cellDimensions)["rows"] as float);
}

def:pub getPngDimensions(base64Data: str) -> any | None {
    try {
        buffer = buffer_from_base64(base64Data);
        if (len(buffer) < 24) {
            return None;
        }
        if ((((buffer[0] != 137) or (buffer[1] != 80)) or (buffer[2] != 78)) or (buffer[3] != 71)) {
            return None;
        }
        width = read_uint32_be(buffer, 16);
        height = read_uint32_be(buffer, 20);
        return {"widthPx": width, "heightPx": height};
    }
    except Exception {
        return None;
    }
}

def:pub getJpegDimensions(base64Data: str) -> any | None {
    try {
        buffer = buffer_from_base64(base64Data);
        if (len(buffer) < 2) {
            return None;
        }
        if ((buffer[0] != 255) or (buffer[1] != 216)) {
            return None;
        }
        offset = 2;
        while (offset < (len(buffer) - 9)) {
            if (buffer[offset] != 255) {
                offset += 1;
                continue;
            }
            marker = buffer[(offset + 1)];
            if ((marker >= 192) and (marker <= 194)) {
                height = read_uint16_be(buffer, (offset + 5));
                width = read_uint16_be(buffer, (offset + 7));
                return {"widthPx": width, "heightPx": height};
            }
            if ((offset + 3) >= len(buffer)) {
                return None;
            }
            length = read_uint16_be(buffer, (offset + 2));
            if (length < 2) {
                return None;
            }
            offset += (2 + length);
        }
        return None;
    }
    except Exception {
        return None;
    }
}

def:pub getGifDimensions(base64Data: str) -> any | None {
    try {
        buffer = buffer_from_base64(base64Data);
        if (len(buffer) < 10) {
            return None;
        }
        sig = ascii_decode(buffer, 0, 6);
        if ((sig != "GIF87a") and (sig != "GIF89a")) {
            return None;
        }
        width = read_uint16_le(buffer, 6);
        height = read_uint16_le(buffer, 8);
        return {"widthPx": width, "heightPx": height};
    }
    except Exception {
        return None;
    }
}

def:pub getWebpDimensions(base64Data: str) -> any | None {
    try {
        buffer = buffer_from_base64(base64Data);
        if (len(buffer) < 30) {
            return None;
        }
        riff = ascii_decode(buffer, 0, 4);
        webp = ascii_decode(buffer, 8, 12);
        if ((riff != "RIFF") or (webp != "WEBP")) {
            return None;
        }
        chunk = ascii_decode(buffer, 12, 16);
        if (chunk == "VP8 ") {
            if (len(buffer) < 30) {
                return None;
            }
            width = float(int(read_uint16_le(buffer, 26)) & int(16383));
            height = float(int(read_uint16_le(buffer, 28)) & int(16383));
            return {"widthPx": width, "heightPx": height};
        }
        elif (chunk == "VP8L") {
            if (len(buffer) < 25) {
                return None;
            }
            bits = read_uint32_le(buffer, 21);
            width = (float(int(bits) & int(16383)) + 1);
            height = (float(int(float(int(bits) >> int(14))) & int(16383)) + 1);
            return {"widthPx": width, "heightPx": height};
        }
        elif (chunk == "VP8X") {
            if (len(buffer) < 30) {
                return None;
            }
            width = (float(int(float(int(buffer[24]) | int(float(int(buffer[25]) << int(8))))) | int(float(int(buffer[26]) << int(16)))) + 1);
            height = (float(int(float(int(buffer[27]) | int(float(int(buffer[28]) << int(8))))) | int(float(int(buffer[29]) << int(16)))) + 1);
            return {"widthPx": width, "heightPx": height};
        }
        return None;
    }
    except Exception {
        return None;
    }
}

def:pub getImageDimensions(base64Data: str, mimeType: str) -> any | None {
    if (mimeType == "image/png") {
        return getPngDimensions(base64Data);
    }
    if (mimeType == "image/jpeg") {
        return getJpegDimensions(base64Data);
    }
    if (mimeType == "image/gif") {
        return getGifDimensions(base64Data);
    }
    if (mimeType == "image/webp") {
        return getWebpDimensions(base64Data);
    }
    return None;
}

def:pub renderImage(base64Data: str, imageDimensions: any, options: any = {}) -> dict[str, str | float | None] | None {
    caps = getCapabilities();
    if not (caps["images"] as any) {
        return None;
    }
    maxWidth = ((lambda (_jx_null4: any) -> any { return (_jx_null4 if _jx_null4 is not None else 80); })(options.get("maxWidthCells")));
    size = calculateImageCellSize(imageDimensions, maxWidth, options.get("maxHeightCells"), getCellDimensions());
    if ((caps["images"] as any) == "kitty") {
        sequence = encodeKitty(base64Data, {"columns": (size["columns"] as float), "rows": (size["rows"] as float), "imageId": options.get("imageId"), "moveCursor": options.get("moveCursor")});
        return {"sequence": sequence, "rows": (size["rows"] as float), "imageId": options.get("imageId")};
    }
    if ((caps["images"] as any) == "iterm2") {
        sequence = encodeITerm2(base64Data, {"width": (size["columns"] as float), "height": "auto", "preserveAspectRatio": ((lambda (_jx_null5: any) -> any { return (_jx_null5 if _jx_null5 is not None else True); })(options.get("preserveAspectRatio")))});
        return {"sequence": sequence, "rows": (size["rows"] as float)};
    }
    return None;
}

def:pub hyperlink(text: str, url: str) -> str {
    return f"{ESC}]8;;{url}{ST}{text}{ESC}]8;;{ST}";
}

def:pub imageFallback(mimeType: str, dimensions: any, filename: str) -> str {
    parts: list[str] = [];
    if filename {
        parts.append(filename);
    }
    parts.append(f"[{mimeType}]");
    if dimensions {
        parts.append(f"{dimensions["widthPx"]}x{dimensions["heightPx"]}");
    }
    return f"[Image: {" ".join(parts)}]";
}
