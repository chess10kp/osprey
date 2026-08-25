"""Context input expansion tests for app/agent/context_input.jac.

Covers: @mention extraction (multiple, none, malformed, invalid paths),
line-range parsing edge cases (reversed, zero, multi-dash, non-numeric),
mention-token resolution including colons in paths, cursor autocomplete
scanning, and end-to-end expansion — plain passthrough, full-file blocks,
line slices with clamping past EOF, missing-file error tolerance with
mixed results, duplicate dedup, large-file truncation, token warning
header, and !command output wrapping (echo-only plus exit-code probing).
Uses Python tempfile dirs (cleaned up per test) so no repo state is
touched -- never real project files.
"""

import os;
import tempfile;
import shutil;


def _make_tmp() -> str {
    return tempfile.mkdtemp(prefix="jackal-context-input-test-");
}


def _cleanup(tmp: str) {
    shutil.rmtree(tmp, ignore_errors=True);
}


def _write_file(path: str, text: str) {
    fn: any = os.path.dirname;
    os.makedirs(fn(path), exist_ok=True);
    fh: any = open(path, "w");
    try {
        fh.write(text);
    } finally {
        fh.close();
    }
}


def _read_text(path: str) -> str {
    fh: any = open(path, "r");
    try {
        return fh.read();
    } finally {
        fh.close();
    }
}


# ============================== path validation ==============================


test "is_valid_file_path rejects traversal, absolute, drive, NUL, blank" {
    assert is_valid_file_path("src/app.py");
    assert is_valid_file_path("a/b/c.txt");
    assert is_valid_file_path("file.jac");
    assert not is_valid_file_path("");
    assert not is_valid_file_path("   ");
    assert not is_valid_file_path("../etc/passwd");
    assert not is_valid_file_path("a/../b");
    assert not is_valid_file_path("/absolute/path");
    assert not is_valid_file_path("\\windows\\path");
    assert not is_valid_file_path("C:\\Users\\x");
    assert not is_valid_file_path("D:/drive");
    assert not is_valid_file_path("bad\0name");
}


# ============================== line range parsing ==============================


test "parse_line_range accepts single lines and ranges" {
    assert parse_line_range("10") == {"start": 10};
    assert parse_line_range("10-20") == {"start": 10, "end": 20};
    assert parse_line_range("5-5") == {"start": 5, "end": 5};
}

test "parse_line_range rejects malformed, zero, and reversed ranges" {
    assert parse_line_range("") is None;
    assert parse_line_range("abc") is None;
    assert parse_line_range("0") is None;
    assert parse_line_range("5-3") is None;      # reversed
    assert parse_line_range("0-4") is None;      # zero start
    assert parse_line_range("-3") is None;       # empty first part
    assert parse_line_range("1-2-3") is None;    # three parts
}


# ============================== mention extraction ==============================


test "parse_file_mentions extracts multiple mentions in order" {
    text = "look at @src/app.py then @README.md:10-20 and @lib/main.jac:3";
    mentions = parse_file_mentions(text);
    assert len(mentions) == 3;
    assert mentions[0]["raw_text"] == "@src/app.py";
    assert mentions[0]["file_path"] == "src/app.py";
    assert mentions[0]["start_index"] == 8;
    assert mentions[0]["end_index"] == 19;
    assert mentions[0]["line_range"] is None;

    assert mentions[1]["raw_text"] == "@README.md:10-20";
    assert mentions[1]["line_range"] == {"start": 10, "end": 20};

    assert mentions[2]["raw_text"] == "@lib/main.jac:3";
    assert mentions[2]["line_range"] == {"start": 3, "end": None};
}

test "parse_file_mentions returns empty for no mentions" {
    assert parse_file_mentions("just plain words") == [];
    assert parse_file_mentions("") == [];
    # Lone @ with nothing after it matches nothing.
    assert parse_file_mentions("email me @ ok") == [];
}

test "parse_file_mentions skips invalid paths and bad ranges" {
    mentions = parse_file_mentions("@../escape and @/abs/path but keep @good.txt:9-2");
    assert len(mentions) == 1;
    assert mentions[0]["file_path"] == "good.txt";
    # Rejected range leaves the mention whole-file.
    assert mentions[0]["raw_text"] == "@good.txt:9-2";
    assert mentions[0]["line_range"] is None;

    # Note: "@C:\win" tokenizes as bare path "C" (colon ends the token), so
    # drive-letter rejection only fires on whole paths, matching the legacy
    # parser exactly. NUL names are rejected here.
    assert [str(m["file_path"]) for m in parse_file_mentions("@x\0y @ok.jac")] == ["ok.jac"];
}


# ============================== token + cursor parsing ==============================


test "parse_mention_token splits path from range suffix" {
    assert parse_mention_token("app.py") == {"path": "app.py"};
    assert parse_mention_token("app.py:12") == {"path": "app.py", "startLine": 12, "endLine": 12};
    assert parse_mention_token("app.py:12-30") == {"path": "app.py", "startLine": 12, "endLine": 30};
    # Last colon wins; earlier colons stay part of the path.
    assert parse_mention_token("a:b:7") == {"path": "a:b", "startLine": 7, "endLine": 7};
    # No leading colon content or non-numeric range: raw passthrough.
    assert parse_mention_token(":10") == {"path": ":10"};
    assert parse_mention_token("file:x") == {"path": "file:x"};
    assert parse_mention_token("f:5-3") == {"path": "f:5-3"};
}


test "get_current_file_mention scans around the cursor for autocomplete" {
    text = "see @src/ma and more";
    # Cursor right after "ma".
    found = get_current_file_mention(text, 11);
    assert found is not None;
    assert found["mention"] == "src/ma";
    assert found["start"] == 4;
    assert found["end"] == 11;
    assert found["rangeSuffix"] == "";

    # Cursor inside a range suffix keeps it separate.
    ranged = get_current_file_mention("use @f.py:10-20 ok", 15);
    assert ranged is not None;
    assert ranged["mention"] == "f.py";
    assert ranged["end"] == 15;
    assert ranged["rangeSuffix"] == ":10-20";

    # Whitespace before the cursor ends scanning backwards.
    assert get_current_file_mention("no at sign here", 15) is None;
    # Default cursor position is end of input.
    tail = get_current_file_mention("hello @notes.md");
    assert tail is not None;
    assert tail["mention"] == "notes.md";
    assert tail["end"] == len("hello @notes.md");
}


# ============================== expansion: passthrough ==============================


test "expand_context_input passes through text without mentions or commands" {
    tmp = _make_tmp();
    try {
        assert expand_context_input(tmp, "") == "";
        assert expand_context_input(tmp, "   ") == "   ";
        assert expand_context_input(tmp, "plain question about jac?") == "plain question about jac?";
        # A bare ! with no command also passes through.
        assert expand_context_input(tmp, "!") == "!";
        assert expand_context_input(tmp, "!   ") == "!   ";
    } finally {
        _cleanup(tmp);
    }
}


# ============================== expansion: file blocks ==============================


test "expand_context_input wraps a whole file in a fenced file block" {
    tmp = _make_tmp();
    try {
        _write_file(os.path.join(tmp, "hello.txt"), "alpha\nbeta\n");
        out = expand_context_input(tmp, "explain @hello.txt please");
        expected_block = '<file path="hello.txt">\n```\nalpha\nbeta\n\n```\n</file>';
        assert out == (
            "explain @hello.txt please\n\nAttached context:\n" + expected_block
        );
    } finally {
        _cleanup(tmp);
    }
}

test "expand_context_input slices line ranges with labeled paths" {
    tmp = _make_tmp();
    try {
        _write_file(os.path.join(tmp, "code.jac"), "l1\nl2\nl3\nl4\nl5\n");
        out = expand_context_input(tmp, "@code.jac:2-4");

        assert '<file path="code.jac:2-4">' in out;
        assert "\nl2\nl3\nl4\n" in out;
        assert "l1" not in out.split("```")[1];
        assert "l5" not in out.split("```")[1];

        single = expand_context_input(tmp, "@code.jac:3");
        assert '<file path="code.jac:3">' in single;
        body = single.split("```")[1];
        assert body.strip() == "l3";
    } finally {
        _cleanup(tmp);
    }
}

test "expand_context_input clamps out-of-bounds ranges like the legacy runtime" {
    tmp = _make_tmp();
    try {
        _write_file(os.path.join(tmp, "short.txt"), "one\ntwo\nthree");
        # End far past EOF clamps to the last line.
        clamped = expand_context_input(tmp, "@short.txt:2-999");
        assert '<file path="short.txt:2-999">' in clamped;
        body = clamped.split("```")[1];
        assert body.strip() == "two\nthree";

        # Start beyond EOF yields an empty slice, not an error.
        past = expand_context_input(tmp, "@short.txt:50");
        assert '<file path="short.txt:50">' in past;
        assert past.split("```")[1].strip() == "";
    } finally {
        _cleanup(tmp);
    }
}

test "expand_context_input tolerates missing files as inline error blocks" {
    tmp = _make_tmp();
    try {
        _write_file(os.path.join(tmp, "real.txt"), "content here");
        out = expand_context_input(tmp, "@ghost.txt and @real.txt");
        assert 'error="' in out;
        assert '<file path="ghost.txt"' in out;
        assert '<file path="real.txt">' in out;
        assert "content here" in out;
        # The turn still completes with an Attached context header.
        assert out.startswith("@ghost.txt and @real.txt\n\nAttached context:");
    } finally {
        _cleanup(tmp);
    }
}

test "expand_context_input dedupes repeated mentions of the same token" {
    tmp = _make_tmp();
    try {
        _write_file(os.path.join(tmp, "dup.txt"), "same");
        out = expand_context_input(tmp, "@dup.txt plus @dup.txt again");
        assert out.count("<file path=\"dup.txt\">") == 1;
        assert out.count("Attached context:") == 1;
    } finally {
        _cleanup(tmp);
    }
}

test "expand_context_input truncates oversized files at the char cap" {
    tmp = _make_tmp();
    try {
        big = "x" * 90000;
        _write_file(os.path.join(tmp, "big.bin"), big);
        out = expand_context_input(tmp, "@big.bin");
        assert "...[truncated at 80000 chars]" in out;
        assert big not in out;
    } finally {
        _cleanup(tmp);
    }
}

test "expand_context_input prepends a token warning above 40k chars" {
    tmp = _make_tmp();
    try {
        medium = "y" * 40001;
        _write_file(os.path.join(tmp, "medium.txt"), medium);
        prompt = "review @medium.txt";
        out = expand_context_input(tmp, prompt);
        assert out.startswith("[Warning: attached files ~10000 tokens]\n");
        assert prompt in out;

        # Under the threshold there is no warning header.
        small = "z" * 1000;
        _write_file(os.path.join(tmp, "small.txt"), small);
        plain = expand_context_input(tmp, "check @small.txt");
        assert "[Warning:" not in plain;
    } finally {
        _cleanup(tmp);
    }
}

test "expand_context_input handles several files end-to-end in one prompt" {
    tmp = _make_tmp();
    try {
        _write_file(os.path.join(tmp, "a.py"), "print('a')\nprint('b')\n");
        _write_file(os.path.join(tmp, "docs", "guide.md"), "# guide\nstep one");
        out = expand_context_input(tmp, "compare @a.py:1 with @docs/guide.md");
        assert out.index('<file path="a.py:1">') < out.index('<file path="docs/guide.md">');
        assert 'print(\'a\')' in out;
        assert "# guide\nstep one" in out;
        assert out.endswith("</file>");
    } finally {
        _cleanup(tmp);
    }
}


# ============================== expansion: !commands ==============================


test "expand_context_input runs echo-only commands into command_output blocks" {
    tmp = _make_tmp();
    try {
        out = expand_context_input(tmp, "!echo jackal-context-test");
        assert out.startswith("User ran inline command: `echo jackal-context-test`");
        assert "<command_output>" in out and "</command_output>" in out;
        assert "stdout:\njackal-context-test" in out;
        assert "exit=0" in out;
        assert out.endswith("Continue based on the command output above.");
    } finally {
        _cleanup(tmp);
    }
}

test "expand_context_input reports failing command exit codes" {
    tmp = _make_tmp();
    try {
        out = expand_context_input(tmp, "!exit 3");
        assert "exit=3" in out;
        assert "<command_output>" in out;
    } finally {
        _cleanup(tmp);
    }
}

test "expand_context_input captures stderr separately from stdout" {
    tmp = _make_tmp();
    try {
        out = expand_context_input(tmp, "!echo out-line; echo err-line 1>&2");
        assert "stdout:\nout-line" in out;
        assert "stderr:\nerr-line" in out;
        assert "exit=0" in out;
    } finally {
        _cleanup(tmp);
    }
}
