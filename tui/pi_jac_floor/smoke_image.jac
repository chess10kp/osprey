"""Runtime smoke for src/components/image.jac (Image component).

Proves end to end: construct an Image from a tiny known 1x1 PNG, render it
under a kitty-capable terminal (escape-sequence path + row count), under an
iterm2-capable terminal (escape-sequence path), and under no image capability
(text fallback path via theme.fallbackColor).

Run: jac run smoke_image.jac
"""

import from src.components.image { Image }
import from src.terminal_image { setCapabilities }

obj FakeTheme {
    def fallbackColor(text: str) -> str {
        return f"[fallback]{text}[/fallback]";
    }
}

with entry {
    # 1x1 PNG (same fixture as smoke_terminal_image.jac)
    pngB64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAA=";
    theme = FakeTheme();

    # --- kitty path: escape sequence + row padding ---
    setCapabilities({"images": "kitty", "trueColor": True, "hyperlinks": True});
    img = Image(pngB64, "image/png", theme, {"maxWidthCells": 10});
    lines = img.render(40.0);
    assert len(lines) >= 1;
    ESC = chr(27);
    assert lines[0].startswith(f"{ESC}_G");
    assert "a=T" in lines[0];
    # remaining lines are blank padding for extra rows (if any)
    for extra in lines[1:] {
        assert extra == "";
    }

    # cache path: re-render at same width returns identical cached lines
    linesAgain = img.render(40.0);
    assert linesAgain is lines;

    # invalidate clears cache
    img.invalidate();
    assert img.cachedLines == None;
    assert img.cachedWidth == None;

    # --- iterm2 path: sequence appended with cursor-move prefix when rows>1 ---
    setCapabilities({"images": "iterm2", "trueColor": True, "hyperlinks": True});
    imgIt = Image(pngB64, "image/png", theme, {"maxWidthCells": 10});
    linesIt = imgIt.render(40.0);
    assert len(linesIt) >= 1;
    lastLine = linesIt[-1];
    assert f"{ESC}]1337;File=" in lastLine;

    # --- fallback path: no image capability -> theme.fallbackColor(text) ---
    setCapabilities({"images": None, "trueColor": False, "hyperlinks": False});
    imgFallback = Image(pngB64, "image/png", theme, {"filename": "cat.png"});
    linesFb = imgFallback.render(40.0);
    assert len(linesFb) == 1;
    assert "[fallback]" in linesFb[0];
    assert "cat.png" in linesFb[0];
    assert "image/png" in linesFb[0];

    # --- getImageId ---
    assert imgFallback.getImageId() == None;
    setCapabilities({"images": "kitty", "trueColor": True, "hyperlinks": True});
    imgWithId = Image(pngB64, "image/png", theme, {"imageId": 42});
    assert imgWithId.getImageId() == 42;

    print("smoke_image OK (kitty escape path / iterm2 path / fallback path / cache / getImageId)");
}
