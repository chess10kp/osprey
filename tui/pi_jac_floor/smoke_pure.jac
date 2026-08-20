"""Runtime smoke for the pure converted slice (fuzzy + utils + unicode_support).

Executes converted logic under the Jac runtime with no Node/terminal deps.
Entry files run directly cannot use relative imports, so the package modules
are addressed absolutely from the project root (jac.toml lives beside this file).

Run: jac run   (or: jac run smoke_pure.jac)
"""

import from src.fuzzy { fuzzyMatch, fuzzyFilter }
import from src.utils { graphemeWidth, isPrintableAscii, visibleWidth }

with entry {
    # fuzzyMatch: subsequence match succeeds, non-match fails.
    assert (fuzzyMatch("fb", "foobar")["matches"] as bool) == True;
    assert (fuzzyMatch("xyz", "foobar")["matches"] as bool) == False;

    # exact match scores best (most negative) vs a loose subsequence.
    exact = fuzzyMatch("foobar", "foobar");
    loose = fuzzyMatch("fb", "foobar");
    assert (exact["score"] as float) < (loose["score"] as float);

    # fuzzyFilter narrows a list by subsequence.
    getText = lambda (x: any) -> str { return (x as str); };
    filtered = fuzzyFilter(["alpha", "beta", "gamma", "gramma"], "gma", getText);
    assert "gamma" in filtered;
    assert "beta" not in filtered;

    # graphemeWidth: ASCII = 1, wide CJK = 2 (unicodedata-backed adapter).
    assert graphemeWidth("a") == 1.0;
    assert graphemeWidth("世") == 2.0;

    # visibleWidth over ASCII, CJK, and an ANSI-wrapped string (SGR stripped).
    assert visibleWidth("ab") == 2.0;
    assert visibleWidth("世界") == 4.0;
    ansi = ("[31m" + "hi" + "[0m");
    assert visibleWidth(ansi) == 2.0;

    # isPrintableAscii guard.
    assert isPrintableAscii("hello") == True;
    assert isPrintableAscii("héllo") == False;

    print("smoke_pure OK");
}
