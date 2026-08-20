"""Runtime smoke parity with tests/tui/text-wrapping.test.mjs (Ink reference).

Maps wrapPlainText / wrapWithTrimmedContinuations expectations onto pi-tui
floor APIs: wrapTextWithAnsi, truncateToWidth, Text.render(), and
TruncatedText.render().

Run: jac check smoke_parity_wrapping.jac && jac run smoke_parity_wrapping.jac
"""

import from src.utils { wrapTextWithAnsi, truncateToWidth, visibleWidth }
import from src.components.text { Text }
import from src.components.truncated_text { TruncatedText }

def buildRepeatedWords(count: int) -> str {
    parts: list[str] = [];
    i: int = 0;
    while (i < count) {
        parts.append("word");
        i += 1;
    }
    return " ".join(parts);
}

with entry {
    # Ink: wrapWithTrimmedContinuations("hello world", 40) == "hello world"
    shortWrapped = wrapTextWithAnsi("hello world", 40.0);
    assert len(shortWrapped) == 1;
    assert shortWrapped[0] == "hello world";

    # Ink: wrapPlainText(long, 20) splits into multiple lines
    longText = buildRepeatedWords(30);
    plainWrapped = wrapTextWithAnsi(longText, 20.0);
    assert len(plainWrapped) > 1;
    for line in plainWrapped {
        assert visibleWidth(line) <= 20.0;
    }

    # truncateToWidth: short text unchanged, long text ellipsized within budget
    assert truncateToWidth("hello", 10.0) == "hello";
    truncated = truncateToWidth("hello world everyone", 10.0);
    assert visibleWidth(truncated) <= 10.0;
    assert "..." in truncated;

    padded = truncateToWidth("hi", 8.0, pad=True);
    assert visibleWidth(padded) == 8.0;
    assert padded.startswith("hi");

    # Text component: short line stays single row; long prose wraps with width padding
    width = 20;
    tShort = Text(text="hello world", paddingX=0, paddingY=0);
    shortLines = tShort.render(float(width));
    assert len(shortLines) == 1;
    assert visibleWidth(shortLines[0]) == float(width);
    assert "hello world" in shortLines[0];

    tLong = Text(text="the quick brown fox jumps over the lazy dog", paddingX=0, paddingY=0);
    longLines = tLong.render(float(width));
    assert len(longLines) >= 2;
    for line in longLines {
        assert visibleWidth(line) == float(width);
    }

    # TruncatedText: single-line ellipsis instead of wrap
    tt = TruncatedText(text="this is a very long line that should not wrap", paddingX=0, paddingY=0);
    truncLines = tt.render(float(width));
    assert len(truncLines) == 1;
    assert visibleWidth(truncLines[0]) == float(width);
    assert "..." in truncLines[0];

    print("smoke_parity_wrapping OK");
}
