# interop import: node:child_process { execSync }
import from os { environ }

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
        termfeatures = execSync("tmux display-message -p '#{client_termfeatures}'", {"encoding": "utf8", "timeout": 250, "stdio": ["ignore", "pipe", "ignore"]});
        return ("hyperlinks" in [feature.strip() for feature in termfeatures.split(",")]);
    }
    except Exception {
        return False;
    }
}

def:pub detectCapabilities(tmuxForwardsHyperlink: any = probeTmuxHyperlinks) -> any {
    termProgram = (((lambda (_jx_opt0: any) -> any { return (_jx_opt0.toLowerCase() if _jx_opt0 is not None else None); })(environ.get("TERM_PROGRAM"))) or "");
    terminalEmulator = (((lambda (_jx_opt1: any) -> any { return (_jx_opt1.toLowerCase() if _jx_opt1 is not None else None); })(environ.get("TERMINAL_EMULATOR"))) or "");
    term = (((lambda (_jx_opt2: any) -> any { return (_jx_opt2.toLowerCase() if _jx_opt2 is not None else None); })(environ.get("TERM"))) or "");
    colorTerm = (((lambda (_jx_opt3: any) -> any { return (_jx_opt3.toLowerCase() if _jx_opt3 is not None else None); })(environ.get("COLORTERM"))) or "");
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

def:pub isImageLine(line: str) -> bool {
    if (line.startswith(KITTY_PREFIX) or line.startswith(ITERM2_PREFIX)) {
        return True;
    }
    return ((KITTY_PREFIX in line) or (ITERM2_PREFIX in line));
}

def:pub allocateImageId() -> float {
    return (int(((Math.random() * 4294967294)) // 1) + 1);
}

def:pub encodeKitty(base64Data: str, options: dict[str, float | None | bool | None] = {}) -> str {
    CHUNK_SIZE = 4096;
    params: list[str] = ["a=T", "f=100", "q=2"];
    if (options.moveCursor == False) {
        params.append("C=1");
    }
    if options.columns {
        params.append(f"c={options.columns}");
    }
    if options.rows {
        params.append(f"r={options.rows}");
    }
    if options.imageId {
        params.append(f"i={options.imageId}");
    }
    if (len(base64Data) <= CHUNK_SIZE) {
        return f"\\x1b_G{",".join(params)};{base64Data}\\x1b\\\\";
    }
    chunks: list[str] = [];
    offset = 0;
    isFirst: bool = True;
    while (offset < len(base64Data)) {
        chunk = base64Data[offset:(offset + CHUNK_SIZE)];
        isLast = ((offset + CHUNK_SIZE) >= len(base64Data));
        if isFirst {
            chunks.append(f"\\x1b_G{",".join(params)},m=1;{chunk}\\x1b\\\\");
            isFirst = False;
        }
        elif isLast {
            chunks.append(f"\\x1b_Gm=0;{chunk}\\x1b\\\\");
        }
        else {
            chunks.append(f"\\x1b_Gm=1;{chunk}\\x1b\\\\");
        }
        offset += CHUNK_SIZE;
    }
    return "".join(chunks);
}

def:pub deleteKittyImage(imageId: float) -> str {
    return f"\\x1b_Ga=d,d=I,i={imageId},q=2\\x1b\\\\";
}

def:pub deleteAllKittyImages() -> str {
    return "\u001b_Ga=d,d=A,q=2\u001b\\";
}

def:pub encodeITerm2(base64Data: str, options: dict[str, float | str | None | str | None | bool | None] = {}) -> str {
    params: list[str] = [f"inline={(1 if (options.inline != False) else 0)}"];
    if (options.width != None) {
        params.append(f"width={options.width}");
    }
    if (options.height != None) {
        params.append(f"height={options.height}");
    }
    if options.name {
        nameBase64: str = Buffer.from(options.name).function toString() {
    [native code]
}("base64");
        params.append(f"name={nameBase64}");
    }
    if (options.preserveAspectRatio == False) {
        params.append("preserveAspectRatio=0");
    }
    return f"\\x1b]1337;File={";".join(params)}:{base64Data}\\x07";
}

def:pub calculateImageCellSize(imageDimensions: any, maxWidthCells: float, maxHeightCells: float, cellDimensions: any = {"widthPx": 9, "heightPx": 18}) -> any {
    maxWidth = max(float(1), float(int((maxWidthCells) // 1)));
    maxHeight = (None if (maxHeightCells == None) else max(float(1), float(int((maxHeightCells) // 1))));
    imageWidth = max(float(1), float(imageDimensions.widthPx));
    imageHeight = max(float(1), float(imageDimensions.heightPx));
    widthScale = ((maxWidth * cellDimensions.widthPx) / imageWidth);
    heightScale = (widthScale if (maxHeight == None) else ((maxHeight * cellDimensions.heightPx) / imageHeight));
    scale = min(float(widthScale), float(heightScale));
    scaledWidthPx = (imageWidth * scale);
    scaledHeightPx = (imageHeight * scale);
    columns = int(-((-(scaledWidthPx / cellDimensions.widthPx)) // 1));
    rows = int(-((-(scaledHeightPx / cellDimensions.heightPx)) // 1));
    return {"columns": max(float(1), float(min(float(maxWidth), float(columns)))), "rows": max(float(1), float((rows if (maxHeight == None) else min(float(maxHeight), float(rows)))))};
}

def:pub calculateImageRows(imageDimensions: any, targetWidthCells: float, cellDimensions: any = {"widthPx": 9, "heightPx": 18}) -> float {
    return (calculateImageCellSize(imageDimensions, targetWidthCells, None, cellDimensions)["rows"] as float);
}

def:pub getPngDimensions(base64Data: str) -> any | None {
    try {
        buffer = Buffer.from(base64Data, "base64");
        if (len(buffer) < 24) {
            return None;
        }
        if ((((buffer[0] != 137) or (buffer[1] != 80)) or (buffer[2] != 78)) or (buffer[3] != 71)) {
            return None;
        }
        width = buffer.readUInt32BE(16);
        height = buffer.readUInt32BE(20);
        return {"widthPx": width, "heightPx": height};
    }
    except Exception {
        return None;
    }
}

def:pub getJpegDimensions(base64Data: str) -> any | None {
    try {
        buffer = Buffer.from(base64Data, "base64");
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
                height = buffer.readUInt16BE((offset + 5));
                width = buffer.readUInt16BE((offset + 7));
                return {"widthPx": width, "heightPx": height};
            }
            if ((offset + 3) >= len(buffer)) {
                return None;
            }
            length = buffer.readUInt16BE((offset + 2));
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
        buffer = Buffer.from(base64Data, "base64");
        if (len(buffer) < 10) {
            return None;
        }
        sig: str = buffer[0:6].function toString() {
    [native code]
}("ascii");
        if ((sig != "GIF87a") and (sig != "GIF89a")) {
            return None;
        }
        width = buffer.readUInt16LE(6);
        height = buffer.readUInt16LE(8);
        return {"widthPx": width, "heightPx": height};
    }
    except Exception {
        return None;
    }
}

def:pub getWebpDimensions(base64Data: str) -> any | None {
    try {
        buffer = Buffer.from(base64Data, "base64");
        if (len(buffer) < 30) {
            return None;
        }
        riff: str = buffer[0:4].function toString() {
    [native code]
}("ascii");
        webp: str = buffer[8:12].function toString() {
    [native code]
}("ascii");
        if ((riff != "RIFF") or (webp != "WEBP")) {
            return None;
        }
        chunk: str = buffer[12:16].function toString() {
    [native code]
}("ascii");
        if (chunk == "VP8 ") {
            if (len(buffer) < 30) {
                return None;
            }
            width = float(int(buffer.readUInt16LE(26)) & int(16383));
            height = float(int(buffer.readUInt16LE(28)) & int(16383));
            return {"widthPx": width, "heightPx": height};
        }
        elif (chunk == "VP8L") {
            if (len(buffer) < 25) {
                return None;
            }
            bits = buffer.readUInt32LE(21);
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
    maxWidth = ((lambda (_jx_null4: any) -> any { return (_jx_null4 if _jx_null4 is not None else 80); })(options.maxWidthCells));
    size = calculateImageCellSize(imageDimensions, maxWidth, options.maxHeightCells, getCellDimensions());
    if ((caps["images"] as any) == "kitty") {
        sequence = encodeKitty(base64Data, {"columns": (size["columns"] as float), "rows": (size["rows"] as float), "imageId": options.imageId, "moveCursor": options.moveCursor});
        return {"sequence": sequence, "rows": (size["rows"] as float), "imageId": options.imageId};
    }
    if ((caps["images"] as any) == "iterm2") {
        sequence = encodeITerm2(base64Data, {"width": (size["columns"] as float), "height": "auto", "preserveAspectRatio": ((lambda (_jx_null5: any) -> any { return (_jx_null5 if _jx_null5 is not None else True); })(options.preserveAspectRatio))});
        return {"sequence": sequence, "rows": (size["rows"] as float)};
    }
    return None;
}

def:pub hyperlink(text: str, url: str) -> str {
    return f"\\x1b]8;;{url}\\x1b\\\\{text}\\x1b]8;;\\x1b\\\\";
}

def:pub imageFallback(mimeType: str, dimensions: any, filename: str) -> str {
    parts: list[str] = [];
    if filename {
        parts.append(filename);
    }
    parts.append(f"[{mimeType}]");
    if dimensions {
        parts.append(f"{dimensions.widthPx}x{dimensions.heightPx}");
    }
    return f"[Image: {" ".join(parts)}]";
}
