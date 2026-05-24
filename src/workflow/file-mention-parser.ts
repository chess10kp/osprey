// Parse @file mentions and line ranges from user input (nanocoder-compatible).

export interface FileMention {
  rawText: string;
  filePath: string;
  lineRange?: { start: number; end?: number };
  startIndex: number;
  endIndex: number;
}

const FILE_MENTION_REGEX = /@([^\s:]+)(?::(\d+)(?:-(\d+))?)?/g;

export function isValidFilePath(filePath: string): boolean {
  if (!filePath || filePath.trim().length === 0) return false;
  const segments = filePath.split(/[/\\]/);
  if (segments.some((seg) => seg === "..")) return false;
  if (filePath.startsWith("/") || filePath.startsWith("\\")) return false;
  if (/^[a-zA-Z]:[/\\]/.test(filePath)) return false;
  if (filePath.includes("\0")) return false;
  return true;
}

export function parseLineRange(
  rangeStr: string,
): { start: number; end?: number } | null {
  if (!rangeStr) return null;
  const parts = rangeStr.split("-");
  if (parts.length === 1) {
    const line = Number.parseInt(parts[0]!, 10);
    if (Number.isNaN(line) || line <= 0) return null;
    return { start: line };
  }
  if (parts.length === 2) {
    const start = Number.parseInt(parts[0]!, 10);
    const end = Number.parseInt(parts[1]!, 10);
    if (Number.isNaN(start) || Number.isNaN(end) || start <= 0 || end < start) return null;
    return { start, end };
  }
  return null;
}

/** Parse all `@path` and `@path:10-20` mentions in input. */
export function parseFileMentions(input: string): FileMention[] {
  const mentions: FileMention[] = [];
  FILE_MENTION_REGEX.lastIndex = 0;

  let match: RegExpExecArray | null;
  while ((match = FILE_MENTION_REGEX.exec(input)) !== null) {
    const rawText = match[0]!;
    const filePath = match[1]!;
    const lineStart = match[2];
    const lineEnd = match[3];

    if (!isValidFilePath(filePath)) continue;

    const mention: FileMention = {
      rawText,
      filePath,
      startIndex: match.index,
      endIndex: match.index + rawText.length,
    };

    if (lineStart) {
      const start = Number.parseInt(lineStart, 10);
      const end = lineEnd ? Number.parseInt(lineEnd, 10) : undefined;
      if (start > 0 && (!end || end >= start)) {
        mention.lineRange = { start, end };
      }
    }

    mentions.push(mention);
  }

  return mentions;
}

/** Path + optional line range from a mention token (no leading `@`). */
export function parseMentionToken(raw: string): {
  path: string;
  startLine?: number;
  endLine?: number;
} {
  const colon = raw.lastIndexOf(":");
  if (colon <= 0) return { path: raw };

  const pathPart = raw.slice(0, colon);
  const rangePart = raw.slice(colon + 1);
  if (!/^\d+(-\d+)?$/.test(rangePart)) return { path: raw };

  const range = parseLineRange(rangePart);
  if (!range) return { path: raw };

  return {
    path: pathPart,
    startLine: range.start,
    endLine: range.end ?? range.start,
  };
}

/** Active `@mention` at cursor for autocomplete. */
export function getCurrentFileMention(
  input: string,
  cursorPosition?: number,
): { mention: string; start: number; end: number; rangeSuffix: string } | null {
  const pos = cursorPosition ?? input.length;

  let start = -1;
  for (let i = pos - 1; i >= 0; i--) {
    const ch = input[i];
    if (ch === "@") {
      start = i;
      break;
    }
    if (ch === " " || ch === "\t" || ch === "\n") break;
  }
  if (start < 0) return null;

  let end = pos;
  for (let i = pos; i < input.length; i++) {
    const ch = input[i];
    if (ch === " " || ch === "\t" || ch === "\n" || ch === "@") break;
    end = i + 1;
  }

  const full = input.slice(start + 1, end);
  const rangeMatch = full.match(/^(.+?)(:\d+(?:-\d*)?)$/);
  const mention = rangeMatch ? rangeMatch[1]! : full;
  const rangeSuffix = rangeMatch ? rangeMatch[2]! : "";

  return { mention, start, end, rangeSuffix };
}
