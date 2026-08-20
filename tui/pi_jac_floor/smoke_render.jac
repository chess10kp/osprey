"""Runtime smoke for component rendering (Text inside Box).

Proves converted components compose and render to a fixed-width line buffer
under the Jac runtime, driven by the unicodedata-backed width/segmentation
adapters. No Node/terminal deps.

Run: jac run smoke_render.jac
"""

import from src.utils { visibleWidth }
import from src.components.text { Text }
import from src.components.box { Box }

with entry {
    width = 20;

    # A Text leaf pads every line to the target width.
    t = Text(text="hello world", paddingX=1, paddingY=0);
    lines = t.render(float(width));
    assert len(lines) >= 1;
    for line in lines {
        assert visibleWidth(line) == float(width);
    }
    assert "hello world" in "".join(lines);

    # Long text wraps to multiple lines, each padded to width.
    t2 = Text(text="the quick brown fox jumps over the lazy dog", paddingX=1, paddingY=0);
    wrapped = t2.render(float(width));
    assert len(wrapped) >= 2;
    for line in wrapped {
        assert visibleWidth(line) == float(width);
    }

    # CJK content still respects the width budget (wide cells count as 2).
    tc = Text(text="世界世界世界世界世界世界", paddingX=1, paddingY=0);
    cjk = tc.render(float(width));
    for line in cjk {
        assert visibleWidth(line) == float(width);
    }

    # Box composes a child and applies vertical padding.
    box = Box(paddingX=1, paddingY=1);
    box.addChild(Text(text="boxed", paddingX=0, paddingY=0));
    rendered = box.render(float(width));
    assert len(rendered) >= 3;  # top pad + content + bottom pad
    assert "boxed" in "".join(rendered);

    print("smoke_render OK (" + str(len(lines)) + "+" + str(len(wrapped)) + " lines)");
}
