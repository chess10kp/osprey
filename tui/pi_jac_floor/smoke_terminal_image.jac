"""Runtime smoke for terminal_image.jac (terminal-image.ts port).

terminal-image.ts is mostly portable byte-parsing/encoding logic (PNG/JPEG/
GIF/WebP header dimension sniffing, Kitty/iTerm2 escape sequence encoding,
image-cell-size math) but the js2jac conversion left Node globals in place:
`Buffer`, `Math.random()`, and `execSync`. The Jac-native `image_support`
adapter reproduces that surface on stdlib `base64`/`random`/`subprocess`.

Proves end to end: image id allocation, Kitty single-chunk and multi-chunk
escape encoding, iTerm2 encoding (including the base64 `name` path), header
dimension parsing for all four image formats against hand-built minimal
headers of known dimensions, mime-type dispatch, cell-size/row math, full
renderImage dict shape, and the plain-string helpers (hyperlink/fallback).

Run: jac run smoke_terminal_image.jac
"""

import from src.terminal_image {
    allocateImageId, encodeKitty, encodeITerm2,
    getPngDimensions, getJpegDimensions, getGifDimensions, getWebpDimensions,
    getImageDimensions, calculateImageCellSize, calculateImageRows,
    renderImage, hyperlink, imageFallback, setCapabilities, getCellDimensions
}

glob ESC = chr(27);

with entry {
    # --- allocateImageId: int in Kitty's valid id range ---
    for _i in range(20) {
        iid = allocateImageId();
        assert isinstance(iid, int) or isinstance(iid, float);
        assert iid >= 1;
        assert iid <= 4294967294;
    }

    # --- encodeKitty: single-chunk path ---
    small = "QUJD";   # short base64 payload, well under the 4096 chunk size
    seq = encodeKitty(small, {"columns": 10, "rows": 5, "imageId": 7});
    assert seq.startswith(f"{ESC}_G");
    assert "a=T" in seq;
    assert "c=10" in seq;
    assert "r=5" in seq;
    assert "i=7" in seq;
    assert seq.endswith(f"{ESC}\\");
    assert (f"{ESC}_G" in seq[1:]) == False;   # exactly one frame in the single-chunk path

    # moveCursor False adds C=1
    seqNoMove = encodeKitty(small, {"moveCursor": False});
    assert "C=1" in seqNoMove;
    # default options (no dict access crash on missing keys)
    seqDefault = encodeKitty(small);
    assert seqDefault.startswith(f"{ESC}_G");

    # --- encodeKitty: multi-chunk path (>4096 base64 chars) ---
    big = "A" * 9000;
    bigSeq = encodeKitty(big, {"imageId": 3});
    # 3 chunks of size 4096: first (m=1 + params), middle... here 9000/4096 -> 3 chunks
    frameStarts = bigSeq.count(f"{ESC}_G");
    assert frameStarts == 3;
    assert "m=1" in bigSeq;      # first + middle chunks carry m=1
    assert "m=0" in bigSeq;      # last chunk closes with m=0
    assert bigSeq.endswith(f"{ESC}\\");

    # --- encodeITerm2 ---
    itSeq = encodeITerm2(small, {"width": 10, "height": "auto"});
    assert itSeq.startswith(f"{ESC}]1337;File=");
    assert "inline=1" in itSeq;
    assert "width=10" in itSeq;
    assert "height=auto" in itSeq;
    assert itSeq.endswith(f"{small}\x07") or itSeq.endswith("\x07");
    assert itSeq.endswith(f"{ESC}\\{small}\x07") or (f":{small}\x07" in itSeq);

    # name option exercises Buffer.from(name).toString("base64") -> to_base64/buffer_from_utf8
    itNamed = encodeITerm2(small, {"name": "photo.png"});
    import base64;
    expectedNameB64 = base64.b64encode("photo.png".encode("utf-8")).decode("ascii");
    assert f"name={expectedNameB64}" in itNamed;

    # preserveAspectRatio False path
    itNoAspect = encodeITerm2(small, {"preserveAspectRatio": False});
    assert "preserveAspectRatio=0" in itNoAspect;

    # --- getPngDimensions: 1x1 PNG (signature + IHDR width/height fields) ---
    pngB64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAA=";
    pngDims = getPngDimensions(pngB64);
    assert pngDims != None;
    assert pngDims["widthPx"] == 1;
    assert pngDims["heightPx"] == 1;

    # --- getJpegDimensions: hand-built SOF0 segment, height=100 width=200 ---
    jpegB64 = "/9j/wAARCABkAMgDASIAAhEBAxEB";
    jpegDims = getJpegDimensions(jpegB64);
    assert jpegDims != None;
    assert jpegDims["widthPx"] == 200;
    assert jpegDims["heightPx"] == 100;

    # --- getGifDimensions: GIF87a signature, width=50 height=30 (LE) ---
    gifB64 = "R0lGODdhMgAeAAAAAA==";
    gifDims = getGifDimensions(gifB64);
    assert gifDims != None;
    assert gifDims["widthPx"] == 50;
    assert gifDims["heightPx"] == 30;

    # --- getWebpDimensions: VP8 (lossy) simple format, width=321 height=241 ---
    webpVp8B64 = "UklGRgAAAABXRUJQVlA4IAoAAAAAAAAAAABBAfEA";
    webpVp8Dims = getWebpDimensions(webpVp8B64);
    assert webpVp8Dims != None;
    assert webpVp8Dims["widthPx"] == 321;
    assert webpVp8Dims["heightPx"] == 241;

    # --- getWebpDimensions: VP8L (lossless), signature byte 0x2F + 14-bit w-1/h-1 ---
    webpVp8lB64 = "UklGRgAAAABXRUJQVlA4TAoAAAAvegALAAAAAAAA";
    webpVp8lDims = getWebpDimensions(webpVp8lB64);
    assert webpVp8lDims != None;
    assert webpVp8lDims["widthPx"] == 123;
    assert webpVp8lDims["heightPx"] == 45;

    # --- getWebpDimensions: VP8X (extended), 24-bit w-1/h-1 fields ---
    webpVp8xB64 = "UklGRgAAAABXRUJQVlA4WAoAAAAAAAAA8wEAKwEA";
    webpVp8xDims = getWebpDimensions(webpVp8xB64);
    assert webpVp8xDims != None;
    assert webpVp8xDims["widthPx"] == 500;
    assert webpVp8xDims["heightPx"] == 300;

    # --- getImageDimensions: mime-type dispatch ---
    assert getImageDimensions(pngB64, "image/png") == pngDims;
    assert getImageDimensions(jpegB64, "image/jpeg") == jpegDims;
    assert getImageDimensions(gifB64, "image/gif") == gifDims;
    assert getImageDimensions(webpVp8B64, "image/webp") == webpVp8Dims;
    assert getImageDimensions(pngB64, "image/unknown") == None;

    # --- calculateImageCellSize / calculateImageRows ---
    dims = {"widthPx": 900, "heightPx": 180};
    cells = calculateImageCellSize(dims, 40.0, 10.0, {"widthPx": 9, "heightPx": 18});
    # width scale: 40*9/900 = 0.4 ; height scale: 10*18/180 = 1.0 -> scale = min = 0.4
    # scaledWidthPx = 360, columns = ceil(360/9) = 40 ; scaledHeightPx = 72, rows = ceil(72/18) = 4
    assert cells["columns"] == 40;
    assert cells["rows"] == 4;

    rows = calculateImageRows(dims, 40.0, {"widthPx": 9, "heightPx": 18});
    assert rows == 4;

    # --- renderImage: full dict shape for a capability ---
    setCapabilities({"images": "kitty", "trueColor": True, "hyperlinks": True});
    result = renderImage(small, dims, {"maxWidthCells": 40.0, "imageId": 99, "moveCursor": False});
    assert result != None;
    assert (result["sequence"] as str).startswith(f"{ESC}_G");
    assert result["imageId"] == 99;
    assert result["rows"] > 0;

    setCapabilities({"images": "iterm2", "trueColor": True, "hyperlinks": True});
    resultIt = renderImage(small, dims, {});
    assert resultIt != None;
    assert (resultIt["sequence"] as str).startswith(f"{ESC}]1337;File=");

    setCapabilities({"images": None, "trueColor": False, "hyperlinks": False});
    assert renderImage(small, dims, {}) == None;

    # --- hyperlink / imageFallback: plain string helpers ---
    link = hyperlink("click me", "https://example.com");
    assert isinstance(link, str);
    assert "https://example.com" in link;
    assert "click me" in link;

    fb = imageFallback("image/png", dims, "cat.png");
    assert isinstance(fb, str);
    assert "cat.png" in fb;
    assert "image/png" in fb;
    assert "900x180" in fb;

    fbNoName = imageFallback("image/gif", None, "");
    assert "image/gif" in fbNoName;

    print("smoke_terminal_image OK (allocateImageId / encodeKitty / encodeITerm2 / png,jpeg,gif,webp dims / cellSize / renderImage / hyperlink / fallback)");
}
