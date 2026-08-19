# interop import: marked { Marked, Tokenizer }
import from "../terminal-image.jac" { getCapabilities, hyperlink, isImageLine }
import from "../utils.jac" { applyBackgroundToLine, visibleWidth, wrapTextWithAnsi }
import from re { compile, split, sub }

glob STRICT_STRIKETHROUGH_REGEX = compile(r"^(~~)(?=[^\s~])((?:\\.|[^\\])*?(?:\\.|[^\s~\\]))\1(?=[^~]|$)");

obj StrictStrikethroughTokenizer(Tokenizer) {
    has lexer: any = None;
    override def del(src: str) -> any | None {
        match_j = STRICT_STRIKETHROUGH_REGEX.exec(src);
        if not match_j {
            return None;
        }
        text = match_j[2];
        return {"type": "del", "raw": match_j[0], "text": text, "tokens": self.lexer.inlineTokens(text)};
    }
}

glob markdownParser: any = Marked();

with entry {
    markdownParser.setOptions({"tokenizer": StrictStrikethroughTokenizer()});
}

# ===== JS2JAC UNCONVERTED (1 decl(s), needs LLM) =====
# JS2JAC-HOLE[E7200] Declaration produced no output:
# | function trimPartialClosingFences(tokens: readonly Token[]): void {
# | 	const token = tokens[tokens.length - 1];
# | 	if (token?.type === "list") {
# | 		trimPartialClosingFences(token.items[token.items.length - 1]?.tokens ?? []);
# | 		return;
# | 	}
# | 	if (token?.type === "blockquote") {
# | 		trimPartialClosingFences(token.tokens ?? []);
# | 		return;
# | 	}
# | 	if (token?.type !== "code") {
# | 		return;
# | 	}
# | 
# | 	// Trim streamed partial closing fences so code blocks do not shrink/flicker
# | 	// when the final fence character arrives. See https://github.com/earendil-works/pi/issues/5825.
# | 	const marker = /^(`{3,}|~{3,})/.exec(token.raw)?.[1];
# | 	const lastLine = token.raw.split("\n").pop();
# | 	if (!marker || !lastLine || lastLine.length >= marker.length || lastLine !== marker[0]?.repeat(lastLine.length)) {
# | 		return;
# | 	}
# | 
# | 	token.text = token.text.slice(0, -lastLine.length).replace(/\n$/, "");
# | }
