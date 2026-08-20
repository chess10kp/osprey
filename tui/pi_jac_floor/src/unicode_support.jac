"""Jac-native Unicode adapters for the ported pi-tui utils.

The js2jac conversion left JS/browser globals in place: `Intl.Segmenter`
(grapheme/word segmentation), the `get-east-asian-width` interop, and several
Unicode-property regexes. Node/stdlib `re` supports none of those and
the frozen Jac runtime cannot pip-install the `regex` module, so this module
reimplements the needed surface on top of the always-available stdlib
`unicodedata`.

Contract reproduced for the converted consumers:
  - GraphemeSegmenter().segment(text)  -> list[Seg]   (Seg.segment is the cluster)
  - WordSegmenter().segment(text)      -> list[Seg]   (Seg.isWordLike set)
  - CjkBreakRegex().test(str)          -> bool
  - eastAsianWidth(cp:int)             -> int
  - isZeroWidth / stripLeadingNonPrinting / isRgiEmoji  (replace prop regexes)

Segmentation is UAX-29-lite: correct for the width, truncation, and wrapping
paths that drive rendering. Full word-boundary parity (findWord*) still depends
on other unconverted JS idioms and is out of scope here.
"""

import from unicodedata { east_asian_width, category }

obj Seg {
    has segment: str = "";
    has index: int = 0;
    has isWordLike: bool = False;
}

def eastAsianWidth(cp: int) -> int {
    w = east_asian_width(chr(cp));
    if ((w == "W") or (w == "F")) {
        return 2;
    }
    return 1;
}

def _isMark(cat: str) -> bool {
    return ((cat == "Mn") or (cat == "Mc") or (cat == "Me"));
}

def _isNonPrinting(cat: str) -> bool {
    return (((cat == "Cc") or (cat == "Cf")) or (cat == "Cs") or _isMark(cat));
}

def isCjkChar(cp: int) -> bool {
    # Han
    if ((((((cp >= 0x3400) and (cp <= 0x4DBF)) or ((cp >= 0x4E00) and (cp <= 0x9FFF)))
          or ((cp >= 0xF900) and (cp <= 0xFAFF))) or ((cp >= 0x20000) and (cp <= 0x2FA1F)))) {
        return True;
    }
    # Hiragana / Katakana
    if ((((cp >= 0x3040) and (cp <= 0x309F)) or ((cp >= 0x30A0) and (cp <= 0x30FF)))
        or ((cp >= 0x31F0) and (cp <= 0x31FF))) {
        return True;
    }
    # Hangul
    if ((((cp >= 0xAC00) and (cp <= 0xD7AF)) or ((cp >= 0x1100) and (cp <= 0x11FF)))
        or ((cp >= 0x3130) and (cp <= 0x318F))) {
        return True;
    }
    # Bopomofo
    if (((cp >= 0x3100) and (cp <= 0x312F)) or ((cp >= 0x31A0) and (cp <= 0x31BF))) {
        return True;
    }
    return False;
}

def isZeroWidth(seg: str) -> bool {
    if (len(seg) == 0) {
        return False;
    }
    for ch in seg {
        if not _isNonPrinting(category(ch)) {
            return False;
        }
    }
    return True;
}

def stripLeadingNonPrinting(seg: str) -> str {
    i = 0;
    while ((i < len(seg)) and _isNonPrinting(category(seg[i]))) {
        i += 1;
    }
    return seg[i:];
}

def isRgiEmoji(seg: str) -> bool {
    if (len(seg) == 0) {
        return False;
    }
    for ch in seg {
        cp = ord(ch);
        if (((cp == 0xFE0F) or (cp == 0x200D))
            or ((cp >= 0x1F1E6) and (cp <= 0x1F1FF))) {
            return True;
        }
        if ((((cp >= 0x1F300) and (cp <= 0x1FAFF)) or ((cp >= 0x2600) and (cp <= 0x27BF)))
            or ((cp >= 0x2B00) and (cp <= 0x2BFF))) {
            return True;
        }
        if (((cp >= 0x2190) and (cp <= 0x21FF)) or ((cp >= 0x2300) and (cp <= 0x23FF))) {
            return True;
        }
    }
    return False;
}

obj GraphemeSegmenter {
    def segment(text: str) -> list[Seg] {
        out: list[Seg] = [];
        n = len(text);
        i = 0;
        while (i < n) {
            start = i;
            first = ord(text[i]);
            i += 1;
            # Regional-indicator flags pair into one grapheme.
            if ((first >= 0x1F1E6) and (first <= 0x1F1FF)) {
                if (((i < n) and (ord(text[i]) >= 0x1F1E6)) and (ord(text[i]) <= 0x1F1FF)) {
                    i += 1;
                }
            }
            cont = True;
            while ((i < n) and cont) {
                cp = ord(text[i]);
                prev = ord(text[(i - 1)]);
                cat = category(text[i]);
                isVS = (((cp >= 0xFE00) and (cp <= 0xFE0F)) or ((cp >= 0xE0100) and (cp <= 0xE01EF)));
                extend = ((((_isMark(cat) or isVS) or (cp == 0x200D)) or (prev == 0x200D)));
                if extend {
                    i += 1;
                }
                else {
                    cont = False;
                }
            }
            out.append(Seg(segment=text[start:i], index=start));
        }
        return out;
    }
}

def _isWordCodepoint(ch: str) -> bool {
    if (ch == "_") {
        return True;
    }
    c = category(ch)[0];
    return (((c == "L") or (c == "N")) or (c == "M"));
}

obj WordSegmenter {
    def segment(text: str) -> list[Seg] {
        out: list[Seg] = [];
        n = len(text);
        i = 0;
        while (i < n) {
            start = i;
            if _isWordCodepoint(text[i]) {
                while ((i < n) and _isWordCodepoint(text[i])) {
                    i += 1;
                }
                out.append(Seg(segment=text[start:i], index=start, isWordLike=True));
            }
            else {
                i += 1;
                out.append(Seg(segment=text[start:i], index=start, isWordLike=False));
            }
        }
        return out;
    }
}

obj CjkBreakRegex {
    def test(s: str) -> bool {
        for ch in s {
            if isCjkChar(ord(ch)) {
                return True;
            }
        }
        return False;
    }
}
