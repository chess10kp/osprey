// ────────────────────────────────────────────────────────────────────────────
// Tool input normalization and compact display labels for the Ink transcript.
// ────────────────────────────────────────────────────────────────────────────

export function normalizeToolInput(raw: unknown): Record<string, unknown> | undefined {
  if (raw == null) return undefined;
  if (typeof raw === "string") {
    const trimmed = raw.trim();
    if (!trimmed) return undefined;
    if (trimmed.startsWith("{") || trimmed.startsWith("[")) {
      try {
        const parsed: unknown = JSON.parse(trimmed);
        if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
          return parsed as Record<string, unknown>;
        }
      } catch {
        /* ignore */
      }
    }
    return undefined;
  }
  if (typeof raw === "object" && !Array.isArray(raw)) {
    return raw as Record<string, unknown>;
  }
  return undefined;
}

export function toolInputField(
  input: Record<string, unknown> | undefined,
  key: string,
): string {
  if (!input) return "";
  const val = input[key];
  if (val !== undefined && val !== null) return String(val);
  return "";
}

export function toolBashCommand(input: Record<string, unknown> | undefined): string {
  const cmd = toolInputField(input, "command");
  return cmd || toolInputField(input, "cmd");
}

export function toolFilePath(input: Record<string, unknown> | undefined): string {
  return (
    toolInputField(input, "path") ||
    toolInputField(input, "file_path") ||
    toolInputField(input, "target_file") ||
    toolInputField(input, "file")
  );
}

function truncate(text: string, max: number): string {
  if (text.length <= max) return text;
  return `${text.slice(0, max - 1)}…`;
}

/** One-line compact label for tool rows (Ctrl+O compact mode). */
export function formatToolSummary(toolName: string, input?: Record<string, unknown>): string {
  if (toolName === "read") {
    const path = toolFilePath(input);
    if (path) return `Read @ ${truncate(path, 60)}`;
    return "Read file";
  }
  if (toolName === "write") {
    const path = toolFilePath(input);
    if (path) return `Wrote → ${truncate(path, 60)}`;
    return "Wrote file";
  }
  if (toolName === "edit") {
    const path = toolFilePath(input);
    if (path) return `Edited ${truncate(path, 60)}`;
    return "Edited file";
  }
  if (toolName === "bash") {
    const cmd = toolBashCommand(input);
    if (cmd) return `$ ${truncate(cmd, 60)}`;
    return "Ran shell command";
  }
  if (toolName === "glob") {
    const pattern = toolInputField(input, "pattern");
    if (pattern) return `Glob ${truncate(pattern, 60)}`;
    return "File search";
  }
  if (toolName === "agent") {
    const task = toolInputField(input, "task") || toolInputField(input, "prompt");
    if (task) return `Subagent: ${truncate(task, 50)}`;
    return "Delegated to subagent";
  }
  if (toolName === "update_task") {
    const updates = input?.updates;
    if (Array.isArray(updates) && updates.length > 0) {
      const first = updates[0] as Record<string, unknown>;
      const id = toolInputField(first, "id");
      const status = toolInputField(first, "status");
      const extra = updates.length > 1 ? ` (+${updates.length - 1})` : "";
      if (id && status) return `Task ${id} → ${status}${extra}`;
      if (id) return `Updated task ${id}${extra}`;
    }
    return "Updated task";
  }
  if (toolName === "create_task") {
    const title = toolInputField(input, "title");
    if (title) return `Created task: ${truncate(title, 50)}`;
    return "Created task";
  }
  if (toolName === "mermaid") return "Rendered diagram";
  if (toolName === "jac_check" || toolName === "jac_check_syntax") return "Ran jac check";
  if (toolName === "jac_run") {
    const file = toolInputField(input, "file") || toolFilePath(input);
    if (file) return `Ran jac ${truncate(file, 50)}`;
    return "Ran jac file";
  }
  if (toolName === "jac_format") return "Formatted jac file(s)";
  if (toolName === "jac_test") return "Ran jac test";
  if (toolName === "jac_fix") return "Ran jac fix loop";
  if (toolName === "jac_doctor") return "Ran jac doctor";
  if (toolName === "jac_create") return "Ran jac create";
  if (toolName === "jac_cli") {
    const args = input?.args;
    if (Array.isArray(args) && args.length > 0) {
      return `jac ${truncate(args.map(String).join(" "), 55)}`;
    }
    return "Ran jac CLI";
  }
  if (toolName === "diagnostics") return "Got diagnostics";
  if (toolName === "hover") return "Looked up type info";
  if (toolName === "definition") return "Found definition";
  if (toolName === "references") return "Found references";
  if (toolName === "web_search") {
    const q = toolInputField(input, "search_term") || toolInputField(input, "query");
    if (q) return `Web search: ${truncate(q, 55)}`;
    return "Web search";
  }
  if (toolName === "web_fetch") {
    const url = toolInputField(input, "url");
    if (url) return `Fetched ${truncate(url, 55)}`;
    return "Fetched URL";
  }
  if (toolName.startsWith("jac_")) return `Ran ${toolName}`;
  return `Ran ${toolName}`;
}

/** Pull path/command from tool result.details when start args were missing. */
export function enrichToolInputFromResult(
  toolName: string,
  input: Record<string, unknown> | undefined,
  result: unknown,
): Record<string, unknown> | undefined {
  const pathTools = new Set(["read", "write", "edit", "jac_run"]);
  if (pathTools.has(toolName) && toolFilePath(input)) return input;
  if (toolName === "bash" && toolBashCommand(input)) return input;

  if (!result || typeof result !== "object") return input;
  const details = (result as { details?: unknown }).details;
  if (!details || typeof details !== "object" || Array.isArray(details)) return input;

  const d = details as Record<string, unknown>;
  const merged = { ...(input ?? {}) };

  if (!toolFilePath(merged)) {
    const path =
      toolInputField(d, "path") ||
      toolInputField(d, "file") ||
      toolInputField(d, "target_file");
    if (path) merged.path = path;
  }
  if (toolName === "bash" && !toolBashCommand(merged)) {
    const cmd = toolInputField(d, "command");
    if (cmd) merged.command = cmd;
  }

  return merged;
}

export function toolEventInput(event: Record<string, unknown>): Record<string, unknown> | undefined {
  return normalizeToolInput(event.input ?? event.args);
}
