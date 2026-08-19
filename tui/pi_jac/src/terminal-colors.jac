def hexToRgb(hex: str) -> any {
    normalized = (hex[1:] if hex.startswith("#") else hex);
    r = parseInt(normalized[0:2], 16);
    g = parseInt(normalized[2:4], 16);
    b = parseInt(normalized[4:6], 16);
    return {"r": r, "g": g, "b": b};
}
