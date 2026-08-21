"""Jackal agent tools - file and shell operations for the ReAct loop.

Server codespace (subprocess/os are server anchors). Pure logic is delegated
to core/ modules which place native by inference.
"""

import os;
import subprocess;
import from core.edit { apply_edit }

glob MAX_TOOL_OUTPUT: int = 50_000,
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

import from .tool_spec { ToolSpec }
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
