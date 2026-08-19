import from "../terminal-image.jac" { allocateImageId, getCapabilities, getCellDimensions, getImageDimensions, imageFallback, renderImage }

obj:pub Image {
    has base64Data: str;
    has mimeType: str;
    has dimensions: any;
    has theme: any;
    has options: any;
    has imageId: float | None = None;
    has cachedLines: list[str] | None = None;
    has cachedWidth: float | None = None;
    def __init__(base64Data: str, mimeType: str, theme: any, options: any = {}, dimensions: any | None = None) -> None {
        self.base64Data = base64Data;
        self.mimeType = mimeType;
        self.theme = theme;
        self.options = options;
        self.dimensions = ((dimensions or getImageDimensions(base64Data, mimeType)) or {"widthPx": 800, "heightPx": 600});
        self.imageId = options.imageId;
    }
    def getImageId() -> float | None {
        return self.imageId;
    }
    def invalidate() -> None {
        self.cachedLines = None;
        self.cachedWidth = None;
    }
    def render(width: float) -> list[str] {
        if (self.cachedLines and (self.cachedWidth == width)) {
            return self.cachedLines;
        }
        maxWidth = max(float(1), float(min(float((width - 2)), float(((lambda (_jx_null0: any) -> any { return (_jx_null0 if _jx_null0 is not None else 60); })(self.options.maxWidthCells))))));
        cellDimensions = getCellDimensions();
        defaultMaxHeight = max(float(1), float(int(-((-((maxWidth * cellDimensions.widthPx) / cellDimensions.heightPx)) // 1))));
        maxHeight = ((lambda (_jx_null1: any) -> any { return (_jx_null1 if _jx_null1 is not None else defaultMaxHeight); })(self.options.maxHeightCells));
        caps = getCapabilities();
        lines: list[str];
        if caps.images {
            if ((caps.images == "kitty") and (self.imageId == None)) {
                self.imageId = allocateImageId();
            }
            result = renderImage(self.base64Data, self.dimensions, {"maxWidthCells": maxWidth, "maxHeightCells": maxHeight, "imageId": self.imageId, "moveCursor": False});
            if result {
                if result.imageId {
                    self.imageId = result.imageId;
                }
                if (caps.images == "kitty") {
                    lines = [result.sequence];
                    i: int = 0;
                    while (i < (result.rows - 1)) {
                        lines.append("");
                        i += 1;
                    }
                }
                else {
                    lines = [];
                    i: int = 0;
                    while (i < (result.rows - 1)) {
                        lines.append("");
                        i += 1;
                    }
                    rowOffset = (result.rows - 1);
                    moveUp = (f"\\x1b[{rowOffset}A" if (rowOffset > 0) else "");
                    lines.append((moveUp + result.sequence));
                }
            }
            else {
                fallback = imageFallback(self.mimeType, self.dimensions, self.options.filename);
                lines = [self.theme.fallbackColor(fallback)];
            }
        }
        else {
            fallback = imageFallback(self.mimeType, self.dimensions, self.options.filename);
            lines = [self.theme.fallbackColor(fallback)];
        }
        self.cachedLines = lines;
        self.cachedWidth = width;
        return lines;
    }
}
