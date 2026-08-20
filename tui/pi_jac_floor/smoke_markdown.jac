"""Runtime smoke for src/components/markdown.jac (Markdown component) and
its src/markdown_support.jac adapter (the Jac-native re-implementation of the
`marked` npm lexer the js2jac conversion left as a dead interop import).

Proves end to end: block lexing (heading, paragraph, fenced code, bullet
list with nesting, blockquote, hr, table) and inline lexing (bold, italic,
codespan, link, and the custom StrictStrikethroughTokenizer.del hook for
~~strikethrough~~) all execute -- not just type-check -- and drive the
Markdown component's render() to produce correctly styled/wrapped terminal
lines.

Run: jac run smoke_markdown.jac
"""

import from src.components.markdown { Markdown }
import from src.markdown_support { Marked, Tokenizer }
import from src.terminal_image { setCapabilities }

obj FakeTheme {
    has codeBlockIndent: str | None = None;
    has highlightCode: any = None;
    def heading(t: str) -> str { return f"H[{t}]"; }
    def link(t: str) -> str { return f"L[{t}]"; }
    def linkUrl(t: str) -> str { return f"U[{t}]"; }
    def code(t: str) -> str { return f"`{t}`"; }
    def codeBlock(t: str) -> str { return t; }
    def codeBlockBorder(t: str) -> str { return t; }
    def quote(t: str) -> str { return t; }
    def quoteBorder(t: str) -> str { return "| "; }
    def hr(t: str) -> str { return t; }
    def listBullet(t: str) -> str { return t; }
    def bold(t: str) -> str { return f"B[{t}]"; }
    def italic(t: str) -> str { return f"I[{t}]"; }
    def strikethrough(t: str) -> str { return f"S[{t}]"; }
    def underline(t: str) -> str { return f"U2[{t}]"; }
}

with entry {
    # Headless terminal: no hyperlink OSC-8 capability, so links render as
    # `text (url)` -- exercises the non-hyperlink branch of renderInlineTokens.
    setCapabilities({"images": None, "trueColor": False, "hyperlinks": False});
    theme = FakeTheme();

    # --- 1. Lexer-level assertions: tokenizer path (headings/lists/code/links/bold/italic) ---
    m = Marked();
    src = "# Title\n\nSome **bold** and *italic* text with a [link](https://example.com).\n\n```python\nprint(1)\n```\n\n- item one\n- item two\n  - nested\n";
    tokens = m.lexer(src);
    assert len(tokens) > 0;
    assert tokens[0].type == "heading";
    assert tokens[0].depth == 1;
    assert tokens[0].text == "Title";

    paraToken = [t for t in tokens if t.type == "paragraph"][0];
    inline = paraToken.tokens;
    assert [t for t in inline if (t.type == "strong")][0].text == "bold";
    assert [t for t in inline if (t.type == "em")][0].text == "italic";
    linkTok = [t for t in inline if (t.type == "link")][0];
    assert linkTok.href == "https://example.com";
    assert linkTok.text == "link";

    codeToken = [t for t in tokens if t.type == "code"][0];
    assert codeToken.lang == "python";
    assert codeToken.text == "print(1)";

    listToken = [t for t in tokens if t.type == "list"][0];
    assert listToken.ordered == False;
    assert len(listToken.items) == 2;
    secondItem = listToken.items[1];
    nestedListTokens = [t for t in secondItem.tokens if (t.type == "list")];
    assert len(nestedListTokens) == 1;
    assert nestedListTokens[0].items[0].raw.strip() == "- nested";

    # --- 2. Strikethrough via the StrictStrikethroughTokenizer.del hook ---
    strikeTokenizer = Marked();
    obj StrictTok(Tokenizer) {
        has lexer: any = None;
        override def del(src: str) -> any | None {
            import re;
            match_j = re.compile(r"^(~~)(?=[^\s~])((?:\\.|[^\\])*?(?:\\.|[^\s~\\]))\1(?=[^~]|$)").match(src);
            if not match_j {
                return None;
            }
            text = match_j.group(2);
            return {"type": "del", "raw": match_j.group(0), "text": text, "tokens": self.lexer.inlineTokens(text)};
        }
    }
    strikeTokenizer.setOptions({"tokenizer": StrictTok()});
    strikeTokens = strikeTokenizer.lexer("Some ~~struck~~ text.");
    strikeInline = strikeTokens[0].tokens;
    delToks = [t for t in strikeInline if (t.type == "del")];
    assert len(delToks) == 1;
    assert delToks[0].text == "struck";

    # --- 3. Full component render(): heading, bold/italic inline, fenced code, bullet list, link ---
    text = "# Title\n\nSome **bold** and *italic* text with a [link](https://example.com).\n\n```python\nprint(1)\n```\n\n- item one\n- item two\n";
    md = Markdown(text, 1.0, 1.0, theme);
    lines = md.render(60.0);
    joined = "\n".join(lines);

    assert "H[B[U2[Title]]]" in joined;                      # heading styling (level 1: heading+bold+underline)
    assert "B[bold]" in joined;                               # bold inline
    assert "I[italic]" in joined;                             # italic inline
    assert "L[U2[link]]" in joined;                            # link text styled
    assert "(https://example.com)" in joined;                  # no-hyperlink-capability fallback shows URL
    assert "```python" in joined;                              # fenced code block border
    assert "print(1)" in joined;                               # fenced code block content
    assert "- item one" in joined;                             # bullet list marker + content
    assert "- item two" in joined;

    # every rendered line is padded to the requested width
    for line in lines {
        assert len(line) == 60;
    }

    # cache path: re-render at the same width returns the identical cached list
    linesAgain = md.render(60.0);
    assert linesAgain is lines;

    # invalidate + setText clears cache and updates content
    md.setText("## Smaller heading");
    assert md.cachedLines == None;
    lines2 = md.render(60.0);
    joined2 = "\n".join(lines2);
    assert "H[B[Smaller heading]]" in joined2;                 # depth>=3 gets literal '#' prefix; depth 2 does not

    # --- 4. Blockquote + hr + table + strikethrough through the full component ---
    text2 = "> a quote\n\n---\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nSome ~~struck~~ text.\n";
    md2 = Markdown(text2, 1.0, 1.0, theme);
    lines2b = md2.render(60.0);
    joined2b = "\n".join(lines2b);
    assert "| I[a quote]" in joined2b;                         # blockquote border + italic quote style
    assert ("─" * 10) in joined2b;                             # hr rule
    assert "B[a]" in joined2b;                                 # table header cell styled bold
    assert "┌" in joined2b and "┐" in joined2b and "└" in joined2b;  # table borders
    assert "S[struck]" in joined2b;                            # strikethrough via custom tokenizer

    # --- 5. Empty text renders no lines ---
    mdEmpty = Markdown("   ", 1.0, 1.0, theme);
    assert mdEmpty.render(60.0) == [];

    print("smoke_markdown OK (lexer: heading/bold/italic/link/code/list-nesting/strikethrough; component: render/cache/invalidate/blockquote/hr/table)");
}
