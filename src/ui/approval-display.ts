// Human-readable summaries and preview lines for tool approval UI in the Ink shell.

const MAX_PREVIEW_CHARS = 1200;
const MAX_LINE_CHARS = 100;
const MAX_WRITE_PREVIEW_LINES = 12;
const MAX_EDIT_PREVIEW_LINES = 16;

export type ApprovalPreviewTone = "default" | "muted" | "added" | "removed" | "error" | "accent";

export interface ApprovalPreviewLine {
  text: string;
  tone?: ApprovalPreviewTone;
}

export interface ApprovalDisplay {
  headline: string;
  /** Prompt shown above the Yes/No selector */
  question: string;
  /** Legacy summary lines (tests, plain fallbacks) */
  detailLines: string[];
  /** Rich preview for the confirmation overlay */
  previewLines: ApprovalPreviewLine[];
}

function truncate(text: string, max: number): string {
  if (text.length <= max) return text;
  return `${text.slice(0, max)}…`;
}

function oneLine(value: unknown): string {
  if (value == null) return "";
  if (typeof value === "string") return value.replace(/\s+/g, " ").trim();
  return JSON.stringify(value);
}

function bashCommand(params: Record<string, unknown>): string | null {
  const cmd = params.command ?? params.cmd;
  return typeof cmd === "string" ? cmd : null;
}

function filePath(params: Record<string, unknown>): string | null {
  for (const key of ["path", "file", "file_path", "target_file"]) {
    const v = params[key];
    if (typeof v === "string" && v.trim()) return v;
  }
  return null;
}

function pushPreview(
  lines: ApprovalPreviewLine[],
  text: string,
  tone: ApprovalPreviewTone = "default",
): void {
  const trimmed = text.trimEnd();
  if (!trimmed) return;
  lines.push({ text: trimmed, tone });
}

function pushBlockLines(
  lines: ApprovalPreviewLine[],
  block: string,
  tone: ApprovalPreviewTone,
  maxLines: number,
): void {
  const parts = block.split("\n");
  const limit = Math.min(parts.length, maxLines);
  for (let i = 0; i < limit; i++) {
    pushPreview(lines, parts[i] ?? "", tone);
  }
  if (parts.length > maxLines) {
    pushPreview(lines, `… (${parts.length - maxLines} more lines)`, "muted");
  }
}

interface EditPair {
  oldText: string;
  newText: string;
}

function collectEdits(params: Record<string, unknown>): EditPair[] {
  const out: EditPair[] = [];
  const edits = params.edits;
  if (Array.isArray(edits)) {
    for (const e of edits) {
      if (!e || typeof e !== "object") continue;
      const row = e as Record<string, unknown>;
      const oldText = row.oldText ?? row.old_string ?? row.old_str;
      const newText = row.newText ?? row.new_string ?? row.new_str;
      if (typeof oldText === "string" && typeof newText === "string") {
        out.push({ oldText, newText });
      }
    }
  }
  const singleOld = params.old_string ?? params.oldText ?? params.old_str;
  const singleNew = params.new_string ?? params.newText ?? params.new_str;
  if (typeof singleOld === "string" && typeof singleNew === "string") {
    out.push({ oldText: singleOld, newText: singleNew });
  }
  return out;
}

function appendEditPreview(lines: ApprovalPreviewLine[], edits: EditPair[]): void {
  if (edits.length === 0) return;
  for (const [i, edit] of edits.entries()) {
    if (edits.length > 1) {
      pushPreview(lines, `Edit ${i + 1}:`, "accent");
    }
    pushPreview(lines, "− remove:", "muted");
    pushBlockLines(lines, edit.oldText, "removed", MAX_EDIT_PREVIEW_LINES);
    pushPreview(lines, "+ add:", "muted");
    pushBlockLines(lines, edit.newText, "added", MAX_EDIT_PREVIEW_LINES);
  }
}

function appendWritePreview(lines: ApprovalPreviewLine[], params: Record<string, unknown>): void {
  const content = params.content;
  if (typeof content !== "string" || !content) return;
  pushPreview(lines, "Content preview:", "accent");
  pushBlockLines(lines, content, "default", MAX_WRITE_PREVIEW_LINES);
}

function appendMcpHint(lines: ApprovalPreviewLine[], toolName: string): void {
  if (!toolName.startsWith("mcp_") && !toolName.startsWith("jac_")) return;
  const label = toolName.startsWith("mcp_") ? "MCP tool" : "Jac tool";
  pushPreview(lines, label, "muted");
}

/** Build headline, question, and preview lines for the approval overlay. */
export function formatApprovalDisplay(
  toolName: string,
  params: Record<string, unknown>,
  options?: { subagentName?: string },
): ApprovalDisplay {
  const previewLines: ApprovalPreviewLine[] = [];
  const detailLines: string[] = [];
  const sub = options?.subagentName?.trim();

  if (sub) {
    detailLines.push(`Subagent: ${sub}`);
    pushPreview(previewLines, `Subagent: ${sub}`, "accent");
  }

  const command = bashCommand(params);
  if (command) {
    detailLines.push(`Command: ${truncate(command, MAX_LINE_CHARS)}`);
    pushPreview(previewLines, "Command:", "muted");
    pushPreview(previewLines, command, "accent");
  }

  const path = filePath(params);
  if (path) {
    detailLines.push(`Path: ${path}`);
    if (!command) {
      pushPreview(previewLines, `Path: ${path}`, "accent");
    }
  }

  if (toolName === "edit" || toolName === "string_replace") {
    const edits = collectEdits(params);
    appendEditPreview(previewLines, edits);
    for (const edit of edits) {
      detailLines.push(`Remove: ${truncate(oneLine(edit.oldText), MAX_LINE_CHARS)}`);
      detailLines.push(`Add: ${truncate(oneLine(edit.newText), MAX_LINE_CHARS)}`);
    }
  }

  if (toolName === "write") {
    appendWritePreview(previewLines, params);
    const content = params.content;
    if (typeof content === "string") {
      detailLines.push(`Bytes: ${content.length}`);
    }
  }

  appendMcpHint(previewLines, toolName);

  const skipKeys = new Set([
    "command",
    "cmd",
    "path",
    "file",
    "file_path",
    "target_file",
    "old_string",
    "new_string",
    "oldText",
    "newText",
    "old_str",
    "new_str",
    "edits",
    "content",
  ]);

  const rest: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(params)) {
    if (!skipKeys.has(k)) rest[k] = v;
  }

  if (Object.keys(rest).length > 0) {
    try {
      const json = JSON.stringify(rest, null, 2);
      const snippet = truncate(json, MAX_PREVIEW_CHARS);
      detailLines.push(snippet);
      pushPreview(previewLines, snippet, "default");
    } catch {
      const snippet = truncate(String(rest), MAX_PREVIEW_CHARS);
      detailLines.push(snippet);
      pushPreview(previewLines, snippet, "default");
    }
  } else if (detailLines.length === (sub ? 1 : 0) && previewLines.length === (sub ? 1 : 0)) {
    try {
      const json = JSON.stringify(params, null, 2);
      const snippet = truncate(json, MAX_PREVIEW_CHARS);
      detailLines.push(snippet);
      pushPreview(previewLines, snippet, "default");
    } catch {
      detailLines.push("(no parameters)");
      pushPreview(previewLines, "(no parameters)", "muted");
    }
  }

  let headline = toolName;
  if (command) headline = `${toolName} — shell command`;
  else if (path) headline = `${toolName} — ${path}`;

  const toolLabel = sub ? `subagent tool "${toolName}"` : `tool "${toolName}"`;
  const question = command
    ? `Execute ${toolLabel}?`
    : `Allow ${toolLabel} to run?`;

  return { headline, question, detailLines, previewLines };
}
