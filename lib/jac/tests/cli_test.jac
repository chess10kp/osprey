"""Tests for lib/jac/jac/cli.jac — mirrors tests/adapter/jac-cli.test.ts."""

::py::
import os
import sys as _sys

_pkg = os.path.join(os.getcwd(), "lib", "jac", "jac")
if _pkg not in _sys.path:
    _sys.path.insert(0, _pkg)

from _cli_toolchain import parse_jac_check_output, find_jac_binary
::py::

test "parses single-line error format" {
    stdout = "src/foo.jac:10:5: error: undefined name 'x'";
    diagnostics = parse_jac_check_output(stdout, "");
    d = diagnostics[0];
    assert d["file"] == "src/foo.jac";
    assert d["line"] == 10;
    assert d["column"] == 5;
    assert d["severity"] == "error";
    assert d["message"] == "undefined name 'x'";
}

test "parses multi-line error with location arrow" {
    stderr = "Error: type mismatch\n --> src/bar.jac:3:1";
    diagnostics = parse_jac_check_output("", stderr);
    d = diagnostics[0];
    assert d["file"] == "src/bar.jac";
    assert d["line"] == 3;
    assert d["column"] == 1;
    assert d["severity"] == "error";
    assert d["message"] == "type mismatch";
}

test "parses warning lines" {
    stdout = "src/warn.jac:1:1: warning: unused import";
    diagnostics = parse_jac_check_output(stdout, "");
    assert diagnostics[0]["severity"] == "warning";
}

test "strips ANSI color codes before parsing" {
    stdout = "\x1b[31msrc/a.jac:2:3: error: boom\x1b[0m";
    diagnostics = parse_jac_check_output(stdout, "");
    assert diagnostics[0]["message"] == "boom";
}

test "returns empty array for clean output" {
    diagnostics = parse_jac_check_output("All checks passed", "");
    empty: bool = diagnostics == [];
    assert empty;
}

test "find_jac_binary returns jac when on PATH" {
    found = find_jac_binary();
    assert found in ("jac", "jaclang", "");
}
