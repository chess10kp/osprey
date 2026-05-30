// Human-readable summaries and preview lines for tool approval UI.
// Pure TypeScript — no bridge subprocess.
// Ported from lib/jac/ui/_approval_display_toolchain.py.

export type ApprovalPreviewTone = "default" | "muted" | "added" | "removed" | "error" | "accent";

export interface ApprovalPreviewLine {
  text: string;
  tone?: ApprovalPreviewTone;
}

export interface ApprovalDisplay {
  headline: string;
  question: string;
  detailLines: string[];
  previewLines: ApprovalPreviewLine[];
}

const MAX_PREVIEW_CHARS = 1200;
const MAX_LINE_CHARS = 100;
const MAX_WRITE_PREVIEW_LINES = 12;
const MAX_EDIT_PREVIEW_LINES = 16;

function truncate(text: string, max = MAX_PREVIEW_CHARS): string {
  return text.length <= max ? text : text.slice(0, max) + "…";
}

function oneLine(value: unknown): string {
  if (value == null) return "";
  if (typeof value === "string") return value.split(/\s+/).join(" ");
  try { return JSON.stringify(value); } catch { return String(value); }
}

function bashCommand(params: Record<string, unknown>): string | undefined {
  const cmd = params.command ?? params.cmd;
  return typeof cmd === "string" ? cmd : undefined;
}

function filePath(params: Record<string, unknown>): string | undefined {
  for (const key of ["path", "file", "file_path", "target_file"] as const) {
    const v = params[key];
    if (typeof v === "string" && v.trim()) return v;
  }
  return undefined;
}

interface EditPair { oldText: string; newText: string }

function collectEdits(params: Record<string, unknown>): EditPair[] {
  const out: EditPair[] = [];

  const edits = params.edits;
  if (Array.isArray(edits)) {
    for (const e of edits) {
      if (!e || typeof e !== "object") continue;
      const oldText = (e as Record<string, unknown>).oldText ?? (e as Record<string, unknown>).old_string ?? (e as Record<string, unknown>).old_str;
      const newText = (e as Record<string, unknown>).newText ?? (e as Record<string, unknown>).new_string ?? (e as Record<string, unknown>).new_str;
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

function pushBlock(
  lines: ApprovalPreviewLine[],
  block: string,
  tone: ApprovalPreviewTone,
  maxLines: number,
): void {
  const parts = block.split("\n");
  const limit = Math.min(parts.length, maxLines);
  for (let i = 0; i < limit; i++) {
    const t = parts[i]!.trimEnd();
    if (t) lines.push({ text: t, tone });
  }
  if (parts.length > maxLines) {
    lines.push({ text: `… (${parts.length - maxLines} more lines)`, tone: "muted" });
  }
}

function appendEditPreview(lines: ApprovalPreviewLine[], edits: EditPair[]): void {
  if (!edits.length) return;
  for (let i = 0; i < edits.length; i++) {
    if (edits.length > 1) lines.push({ text: `Edit ${i + 1}:`, tone: "accent" });
    lines.push({ text: "− remove:", tone: "muted" });
    pushBlock(lines, edits[i]!.oldText, "removed", MAX_EDIT_PREVIEW_LINES);
    lines.push({ text: "+ add:", tone: "muted" });
    pushBlock(lines, edits[i]!.newText, "added", MAX_EDIT_PREVIEW_LINES);
  }
}

function appendWritePreview(lines: ApprovalPreviewLine[], params: Record<string, unknown>): void {
  const { content } = params;
  if (typeof content !== "string" || !content) return;
  lines.push({ text: "Content preview:", tone: "accent" });
  pushBlock(lines, content, "default", MAX_WRITE_PREVIEW_LINES);
}

const SKIP_KEYS = new Set([
  "command", "cmd", "path", "file", "file_path", "target_file",
  "old_string", "new_string", "oldText", "newText", "old_str", "new_str",
  "edits", "content",
]);

export function formatApprovalDisplay(
  toolName: string,
  params: Record<string, unknown>,
  options?: { subagentName?: string },
): ApprovalDisplay {
  const preview: ApprovalPreviewLine[] = [];
  const detail: string[] = [];

  const sub = options?.subagentName?.trim();
  if (sub) {
    detail.push(`Subagent: ${sub}`);
    preview.push({ text: `Subagent: ${sub}`, tone: "accent" });
  }

  const command = bashCommand(params);
  if (command) {
    detail.push(`Command: ${truncate(command, MAX_LINE_CHARS)}`);
    preview.push({ text: "Command:", tone: "muted" });
    preview.push({ text: command, tone: "accent" });
  }

  const fpath = filePath(params);
  if (fpath) {
    detail.push(`Path: ${fpath}`);
    if (!command) preview.push({ text: `Path: ${fpath}`, tone: "accent" });
  }

  if (toolName === "edit" || toolName === "string_replace") {
    const edits = collectEdits(params);
    appendEditPreview(preview, edits);
    for (const edit of edits) {
      detail.push(`Remove: ${truncate(oneLine(edit.oldText), MAX_LINE_CHARS)}`);
      detail.push(`Add: ${truncate(oneLine(edit.newText), MAX_LINE_CHARS)}`);
    }
  }

  if (toolName === "write") {
    appendWritePreview(preview, params);
    const { content } = params;
    if (typeof content === "string") detail.push(`Bytes: ${content.length}`);
  }

  if (toolName.startsWith("mcp_") || toolName.startsWith("jac_")) {
    const label = toolName.startsWith("mcp_") ? "MCP tool" : "Jac tool";
    preview.push({ text: label, tone: "muted" });
  }

  const rest: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(params)) {
    if (!SKIP_KEYS.has(k)) rest[k] = v;
  }
  if (Object.keys(rest).length > 0) {
    let snippet: string;
    try { snippet = truncate(JSON.stringify(rest, undefined, 2)); } catch { snippet = truncate(String(rest)); }
    detail.push(snippet);
    preview.push({ text: snippet, tone: "default" });
  } else if (detail.length === (sub ? 1 : 0) && preview.length === (sub ? 1 : 0)) {
    let snippet: string;
    try { snippet = truncate(JSON.stringify(params, undefined, 2)); } catch { snippet = "(no parameters)"; }
    if (snippet === "(no parameters)") preview.push({ text: "(no parameters)", tone: "muted" });
    detail.push(snippet);
    if (!snippet.includes("(no parameters)")) preview.push({ text: snippet, tone: "default" });
  }

  let headline = toolName;
  if (command) headline = `${toolName} — shell command`;
  else if (fpath) headline = `${toolName} — ${fpath}`;

  const toolLabel = sub ? `subagent tool "${toolName}"` : `tool "${toolName}"`;
  const question = command ? `Execute ${toolLabel}?` : `Allow ${toolLabel} to run?`;

  return { headline, question, detailLines: detail, previewLines: preview };
}
