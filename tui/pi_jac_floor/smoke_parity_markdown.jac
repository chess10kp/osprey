"""Runtime smoke parity with tests/tui/markdown.test.mjs table expectations.

Focuses on Markdown.render() table output (borders, cell stripping, alignment,
embedded tables) matching parseMarkdownTable / parseMarkdownParts cases
where applicable to the pi-tui Markdown component API.

Run: jac check smoke_parity_markdown.jac && jac run smoke_parity_markdown.jac
"""

import from src.components.markdown { Markdown }
import from src.terminal_image { setCapabilities }

obj FakeTheme {
    has codeBlockIndent: str | None = None;
    has highlightCode: any | None = None;
    def heading(t: str) -> str { return t; }
    def link(t: str) -> str { return t; }
    def linkUrl(t: str) -> str { return t; }
    def code(t: str) -> str { return t; }
    def codeBlock(t: str) -> str { return t; }
    def codeBlockBorder(t: str) -> str { return t; }
    def quote(t: str) -> str { return t; }
    def quoteBorder(t: str) -> str { return t; }
    def hr(t: str) -> str { return t; }
    def listBullet(t: str) -> str { return t; }
    def bold(t: str) -> str { return t; }
    def italic(t: str) -> str { return t; }
    def strikethrough(t: str) -> str { return t; }
    def underline(t: str) -> str { return t; }
}

def hasTableBorder(text: str) -> bool {
    return (("─" in text) or ("│" in text));
}

with entry {
    setCapabilities({"images": None, "trueColor": False, "hyperlinks": False});
    theme = FakeTheme();
    renderWidth = 80.0;

    # fixture: simple two-column table with borders
    table = "| Name | Age |\n|------|-----|\n| John | 25  |\n| Jane | 30  |";
    md = Markdown(table, 0.0, 0.0, theme, None, None);
    joined = "\n".join(md.render(renderWidth));
    assert "Name" in joined;
    assert "Age" in joined;
    assert "John" in joined;
    assert "Jane" in joined;
    assert "25" in joined;
    assert "30" in joined;
    assert hasTableBorder(joined);

    # fixture: invalid table input stays plain text (no box drawing)
    mdPlain = Markdown("Not a table at all", 0.0, 0.0, theme, None, None);
    plainJoined = "\n".join(mdPlain.render(renderWidth));
    assert "Not a table at all" in plainJoined;
    assert not hasTableBorder(plainJoined);

    # fixture: markdown formatting stripped from rendered table cells
    fmtTable = "| Command | Description |\n|---------|-------------|\n| `npm install` | Install **dependencies** |";
    fmtJoined = "\n".join(Markdown(fmtTable, 0.0, 0.0, theme, None, None).render(100.0));
    assert "npm install" in fmtJoined;
    assert "dependencies" in fmtJoined;
    assert "**dependencies**" not in fmtJoined;
    assert "`npm install`" not in fmtJoined;

    # fixture: alignment markers in separator row
    alignTable = "| Left | Center | Right |\n|:-----|:------:|------:|\n| A    | B      | C     |";
    alignJoined = "\n".join(Markdown(alignTable, 0.0, 0.0, theme, None, None).render(100.0));
    assert "Left" in alignJoined;
    assert "Center" in alignJoined;
    assert "Right" in alignJoined;
    assert hasTableBorder(alignJoined);

    # fixture: table embedded in prose (parseMarkdownParts with tables)
    mdBlock = "Here is a table:\n\n| Tool | Status |\n|------|--------|\n| read | Done   |\n| write | Done  |\n\nDone.";
    blockJoined = "\n".join(Markdown(mdBlock, 0.0, 0.0, theme, None, None).render(100.0));
    assert "Here is a table:" in blockJoined;
    assert "Tool" in blockJoined;
    assert "Status" in blockJoined;
    assert "read" in blockJoined;
    assert "write" in blockJoined;
    assert "Done." in blockJoined;
    assert hasTableBorder(blockJoined);

    # fixture: table without trailing newline on last row — no raw markdown rule row
    noNlTable = "| Name | Value |\n|------|-------|\n| foo  | bar   |";
    noNlJoined = "\n".join(Markdown(noNlTable, 0.0, 0.0, theme, None, None).render(100.0));
    assert "foo" in noNlJoined;
    assert "bar" in noNlJoined;
    assert hasTableBorder(noNlJoined);
    assert "|------|" not in noNlJoined;

    print("smoke_parity_markdown OK");
}
