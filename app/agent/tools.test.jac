"""Tests for agent/tools.jac (same-stem annex, merged with the base module
at test time - no import of the own stem). Covers glob and grep search
behavior including generated-directory skips and result caps.
"""

import from .modes { is_tool_blocked }

test "glob finds files and skips generated directories" {
    tmp = tempfile.mkdtemp();
    try {
        os.makedirs(os.path.join(tmp, "src"));
        os.makedirs(os.path.join(tmp, "node_modules"));
        with open(os.path.join(tmp, "src", "one.jac"), "w") as f { f.write("one"); }
        with open(os.path.join(tmp, "node_modules", "hidden.jac"), "w") as f { f.write("skip"); }
        found = file_glob("**/*.jac", tmp);
        assert "src/one.jac" in found;
        assert "hidden.jac" not in found;
    } finally {
        shutil.rmtree(tmp, ignore_errors=True);
    }
}


test "grep finds literal and regex matches with a cap" {
    tmp = tempfile.mkdtemp();
    try {
        with open(os.path.join(tmp, "notes.txt"), "w") as f {
            f.write("needle one\nneedle two\nneedle three\n");
        }
        literal = content_grep("needle", tmp, False, 2);
        assert "notes.txt:1:needle one" in literal;
        assert "notes.txt:2:needle two" in literal;
        assert "truncated at 2 matches" in literal;
        regex = content_grep("needle [ot]wo", tmp, True);
        assert "notes.txt:2:needle two" in regex;
    } finally {
        shutil.rmtree(tmp, ignore_errors=True);
    }
}


test "jac_check and jac_format register with correct read-only blocking" {
    reg = default_registry();
    names = [spec.name for spec in tool_specs()];
    assert "jac_check" in names;
    assert "jac_format" in names;
    # jac_format mutates files -> blocked in plan/ask; jac_check stays allowed.
    assert is_tool_blocked("plan", "jac_format") is True;
    assert is_tool_blocked("ask", "jac_format") is True;
    assert is_tool_blocked("normal", "jac_format") is False;
    assert is_tool_blocked("plan", "jac_check") is False;
}


test "jac_check and jac_format reject missing paths without spawning" {
    res = jac_check("/nonexistent/jackal/path.jac");
    assert res.startswith("ERROR:");
    fmt = jac_format("/nonexistent/jackal/path.jac");
    assert fmt.startswith("ERROR:");
}
