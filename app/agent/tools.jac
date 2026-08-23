"""Jackal agent tools - file and shell operations for the ReAct loop.

Server codespace (subprocess/os are server anchors). Pure logic is delegated
to core/ modules which place native by inference.
"""

import os;
import subprocess;
import tempfile;
import shutil;
import fnmatch;
import re;
import from core.edit { apply_edit }
import from .tool_spec { ToolSpec, MAX_TOOL_RESULT, MAX_SEARCH_RESULTS }

glob MAX_TOOL_OUTPUT: int = MAX_TOOL_RESULT,
     READ_LINE_CAP: int = 2_000;

"""Resolve a path against the process cwd; reject empty paths."""
def resolve_path(path: str) -> str {
    if not path { raise ValueError("path must not be empty"); }
    return path if os.path.isabs(path) else os.path.join(os.getcwd(), path);
}
sem resolve_path = "Resolve a possibly-relative path to an absolute one. Internal helper.";
sem resolve_path.path = "Filesystem path, relative or absolute.";

def read_file(path: str) -> str {
    full = resolve_path(path);
    with open(full, "r", errors="replace") as f { text = f.read(); }
    lines = text.split("\n");
    if len(lines) > READ_LINE_CAP {
        lines = lines[:READ_LINE_CAP];
        lines.append("... [truncated at " + str(READ_LINE_CAP) + " lines]");
    }
    if len(text) > MAX_TOOL_OUTPUT { return text[:MAX_TOOL_OUTPUT]; }
    return "\n".join(lines);
}
sem read_file = "Read a text file and return its contents. Use this before editing a file you have not seen this session.";
sem read_file.path = "Filesystem path to read, relative to the project root.";

def write_file(path: str, content: str) -> str {
    full = resolve_path(path);
    d = os.path.dirname(full);
    if d { os.makedirs(d, exist_ok=True); }
    with open(full, "w") as f { f.write(content); }
    return f"Wrote {len(content)} bytes to {path}";
}
sem write_file = "Create or completely overwrite a file with the given content. Prefer edit_file for small changes to existing files.";
sem write_file.path = "Filesystem path to write.";
sem write_file.content = "Full file content to write.";

def edit_file(path: str, old_text: str, new_text: str) -> str {
    full = resolve_path(path);
    with open(full, "r", errors="replace") as f { text = f.read(); }
    result = apply_edit(text, old_text, new_text);
    if result.startswith("ERROR:") { return result; }
    with open(full, "w") as f { f.write(result); }
    return f"Edited {path} ({len(old_text)} -> {len(new_text)} chars)";
}
sem edit_file = "Replace an exact, unique snippet in a file. old_text must match the file byte-for-byte and appear exactly once; on failure read the file again and retry with a wider or corrected snippet.";
sem edit_file.path = "Filesystem path of the file to edit.";
sem edit_file.old_text = "Exact existing text to replace, including indentation.";
sem edit_file.new_text = "Replacement text.";

def list_dir(path: str) -> str {
    full = resolve_path(path);
    names = sorted(os.listdir(full));
    out: list[str] = [];
    for n in names {
        if n.startswith(".") { continue; }
        label = n + "/" if os.path.isdir(os.path.join(full, n)) else n;
        out.append(label);
    }
    return "\n".join(out[:500]);
}
sem list_dir = "List immediate entries of a directory (dotfiles hidden, directories suffixed with /). Use for exploration before reading files.";
sem list_dir.path = "Directory path to list.";

def run_command(cmd: str, timeout_secs: int = 120) -> str {
    try {
        r = subprocess.run(
            cmd, shell=True, capture_output=True, text=True,
            timeout=timeout_secs if timeout_secs > 0 else 120,
        );
    } except subprocess.TimeoutExpired {
        return f"ERROR: command timed out after {timeout_secs}s";
    }
    out = (r.stdout or "") + (r.stderr or "");
    if len(out) > MAX_TOOL_OUTPUT { out = out[:MAX_TOOL_OUTPUT] + "\n... [truncated]"; }
    return f"exit={r.returncode}\n{out.strip()}";
}
sem run_command = "Run a shell command in the project root and return exit code plus combined stdout/stderr. Use for builds, tests, git, and inspection commands.";
sem run_command.cmd = "The shell command line to execute.";
sem run_command.timeout_secs = "Seconds before the command is killed (default 120).";


"""Run the jac CLI with args and format exit status plus output for the LLM."""
def _run_jac_cli(args: list[str], timeout_secs: int = 120) -> str {
    effective = timeout_secs if timeout_secs > 0 else 120;
    try {
        r = subprocess.run(
            ["jac"] + args, capture_output=True, text=True, timeout=effective,
        );
    } except FileNotFoundError {
        return "ERROR: jac CLI not found on PATH";
    } except subprocess.TimeoutExpired {
        return f"ERROR: jac {' '.join(args)} timed out after {effective}s";
    }
    out = (r.stdout or "") + (r.stderr or "");
    if len(out) > MAX_TOOL_OUTPUT { out = out[:MAX_TOOL_OUTPUT] + "\n... [truncated]"; }
    status = "ok" if r.returncode == 0 else f"failed (exit {r.returncode})";
    body = out.strip() if out.strip() else "(no output)";
    return f"jac {' '.join(args)} -> {status}\n{body}";
}

"""Type-check / compile-check Jac files or a whole project via `jac check`."""
def jac_check(path: str = ".") -> str {
    full = resolve_path(path);
    if not os.path.exists(full) {
        return f"ERROR: no such file or directory: {path}";
    }
    return _run_jac_cli(["check", full]);
}
sem jac_check = "Check Jac files for syntax/type errors with the Jac toolchain. Read-only; run this after editing .jac files.";
sem jac_check.path = "File or directory to check (default: project root).";

"""Format Jac files in place via `jac format`. Blocked in plan/ask modes."""
def jac_format(path: str = ".") -> str {
    full = resolve_path(path);
    if not os.path.exists(full) {
        return f"ERROR: no such file or directory: {path}";
    }
    return _run_jac_cli(["format", full]);
}
sem jac_format = "Format Jac files in place with the Jac formatter. Modifies files on disk.";
sem jac_format.path = "File or directory to format (default: project root).";


def _skip_walk_dir(name: str) -> bool {
    return name.startswith(".") or name in ["node_modules", ".jac", "__pycache__"];
}


def _search_limit(limit: int) -> int {
    if limit <= 0 { return MAX_SEARCH_RESULTS; }
    return min(limit, MAX_SEARCH_RESULTS);
}


def file_glob(pattern: str, base_dir: str = ".", max_results: int = MAX_SEARCH_RESULTS) -> str {
    if not pattern { return "ERROR: pattern must not be empty"; }
    base_path = resolve_path(base_dir);
    if not os.path.isdir(base_path) { return f"ERROR: directory not found: {base_dir}"; }
    cap = _search_limit(max_results);
    matches: list[str] = [];
    for walk_item in os.walk(base_path) {
        current = walk_item[0];
        dirs = walk_item[1];
        files = walk_item[2];
        dirs[:] = [d for d in dirs if not _skip_walk_dir(d)];
        for name in files {
            if name.startswith(".") { continue; }
            full = os.path.join(current, name);
            rel = os.path.relpath(full, base_path).replace(os.sep, "/");
            if fnmatch.fnmatch(rel, pattern) or fnmatch.fnmatch(name, pattern) {
                matches.append(rel);
            }
        }
    }
    matches.sort();
    truncated = len(matches) > cap;
    visible = matches[:cap];
    out = "\n".join(visible);
    if truncated { out += ("\n" if out else "") + f"... [truncated at {cap} results]"; }
    return out;
}
sem file_glob = "Find files matching a pattern under the project root. Hidden directories, node_modules, .jac, and __pycache__ are skipped.";
sem file_glob.pattern = "Shell-style file pattern such as **/*.jac or *.md.";
sem file_glob.base_dir = "Directory to search, relative to the project root (default .).";
sem file_glob.max_results = "Maximum results to return, capped at 100.";


def content_grep(pattern: str, base_dir: str = ".", regex: bool = False, max_results: int = MAX_SEARCH_RESULTS) -> str {
    if not pattern { return "ERROR: pattern must not be empty"; }
    base_path = resolve_path(base_dir);
    if not os.path.isdir(base_path) { return f"ERROR: directory not found: {base_dir}"; }
    cap = _search_limit(max_results);
    matcher: any = None;
    if regex {
        try { matcher = re.compile(pattern); }
        except re.error as e { return f"ERROR: invalid regex: {e}"; }
    }
    matches: list[str] = [];
    for walk_item in os.walk(base_path) {
        current = walk_item[0];
        dirs = walk_item[1];
        files = walk_item[2];
        dirs[:] = [d for d in dirs if not _skip_walk_dir(d)];
        for name in files {
            if name.startswith(".") { continue; }
            full = os.path.join(current, name);
            rel = os.path.relpath(full, base_path).replace(os.sep, "/");
            try {
                with open(full, "r", errors="replace") as f { lines = f.readlines(); }
            } except (OSError, UnicodeError) { continue; }
            for line_item in enumerate(lines, 1) {
                line_no = line_item[0];
                line = line_item[1];
                text = line.rstrip("\n");
                found = matcher.search(text) if regex else pattern in text;
                if found {
                    matches.append(f"{rel}:{line_no}:{text[:500]}");
                }
            }
        }
    }
    matches.sort();
    truncated = len(matches) > cap;
    visible = matches[:cap];
    out = "\n".join(visible);
    if truncated { out += ("\n" if out else "") + f"... [truncated at {cap} matches]"; }
    return out;
}
sem content_grep = "Search file contents for a literal or regular-expression pattern under the project root. Hidden directories, node_modules, .jac, and __pycache__ are skipped.";
sem content_grep.pattern = "Text or regular expression to search for.";
sem content_grep.base_dir = "Directory to search, relative to the project root (default .).";
sem content_grep.regex = "Use regular-expression matching instead of literal matching (default false).";
sem content_grep.max_results = "Maximum matches to return, capped at 100.";

import from .registry {
    ToolRegistry,
    create_registry,
    register_native_spec,
}

"""Explicit tool specs for the owned loop (replaces byllm sem-string schema
derivation). When tools become Cordis fibers, live providers of "tools.*"
keys build this list dynamically."""
def tool_specs() -> list[ToolSpec] {
    return [
        ToolSpec(
            name="read_file",
            description="Read a text file and return its contents. Use this before editing a file you have not seen this session.",
            parameters={
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Filesystem path to read, relative to the project root."},
                },
                "required": ["path"],
            },
            handler=read_file,
        ),
        ToolSpec(
            name="write_file",
            description="Create or completely overwrite a file with the given content. Prefer edit_file for small changes to existing files.",
            parameters={
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Filesystem path to write."},
                    "content": {"type": "string", "description": "Full file content to write."},
                },
                "required": ["path", "content"],
            },
            handler=write_file,
        ),
        ToolSpec(
            name="edit_file",
            description="Replace an exact, unique snippet in a file. old_text must match the file byte-for-byte and appear exactly once.",
            parameters={
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Filesystem path of the file to edit."},
                    "old_text": {"type": "string", "description": "Exact existing text to replace, including indentation."},
                    "new_text": {"type": "string", "description": "Replacement text."},
                },
                "required": ["path", "old_text", "new_text"],
            },
            handler=edit_file,
        ),
        ToolSpec(
            name="list_dir",
            description="List immediate entries of a directory (dotfiles hidden, directories suffixed with /).",
            parameters={
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Directory path to list."},
                },
                "required": ["path"],
            },
            handler=list_dir,
        ),
        ToolSpec(
            name="run_command",
            description="Run a shell command in the project root and return exit code plus combined stdout/stderr.",
            parameters={
                "type": "object",
                "properties": {
                    "cmd": {"type": "string", "description": "The shell command line to execute."},
                    "timeout_secs": {"type": "integer", "description": "Seconds before the command is killed (default 120)."},
                },
                "required": ["cmd"],
            },
            handler=run_command,
        ),
        ToolSpec(
            name="jac_check",
            description="Check Jac files for syntax and type errors using the Jac toolchain (jac check). Prefer this over run_command for validating .jac edits.",
            parameters={
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "File or directory to check (default: project root)."},
                },
                "required": [],
            },
            handler=jac_check,
        ),
        ToolSpec(
            name="jac_format",
            description="Format Jac files in place with the Jac formatter (jac format). Modifies files; blocked in plan/ask modes.",
            parameters={
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "File or directory to format (default: project root)."},
                },
                "required": [],
            },
            handler=jac_format,
        ),
        ToolSpec(
            name="glob",
            description="Find files matching a pattern under the project root, skipping hidden and generated directories.",
            parameters={
                "type": "object",
                "properties": {
                    "pattern": {"type": "string", "description": "Shell-style file pattern such as **/*.jac."},
                    "base_dir": {"type": "string", "description": "Directory to search (default .)."},
                    "max_results": {"type": "integer", "description": "Maximum results, capped at 100."},
                },
                "required": ["pattern"],
            },
            handler=file_glob,
        ),
        ToolSpec(
            name="grep",
            description="Search file contents for a literal or regular-expression pattern under the project root.",
            parameters={
                "type": "object",
                "properties": {
                    "pattern": {"type": "string", "description": "Text or regular expression to search for."},
                    "base_dir": {"type": "string", "description": "Directory to search (default .)."},
                    "regex": {"type": "boolean", "description": "Use regex matching instead of literal matching."},
                    "max_results": {"type": "integer", "description": "Maximum matches, capped at 100."},
                },
                "required": ["pattern"],
            },
            handler=content_grep,
        ),
    ];
}


"""Fresh registry seeded with native tool_specs(). Js tools join via plugin_bridge."""
def default_registry() -> ToolRegistry {
    reg = create_registry();
    for spec in tool_specs() {
        register_native_spec(reg, spec);
    }
    return reg;
}


