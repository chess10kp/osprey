/** Parse YAML-like frontmatter from markdown (--- delimited). */

export interface ParsedFrontmatter {
  frontmatter: Record<string, string | string[]>;
  body: string;
}

function parseScalar(value: string): string | string[] {
  const trimmed = value.trim();
  if (!trimmed) return "";

  if (
    (trimmed.startsWith('"') && trimmed.endsWith('"')) ||
    (trimmed.startsWith("'") && trimmed.endsWith("'"))
  ) {
    return trimmed.slice(1, -1);
  }

  if (trimmed.startsWith("[") && trimmed.endsWith("]")) {
    const inner = trimmed.slice(1, -1).trim();
    if (!inner) return [];
    return inner
      .split(",")
      .map((part) => part.trim().replace(/^['"]|['"]$/g, ""))
      .filter(Boolean);
  }

  return trimmed;
}

export function parseFrontmatter(content: string): ParsedFrontmatter {
  const frontmatter: Record<string, string | string[]> = {};
  const normalized = content.replace(/\r\n/g, "\n");

  if (!normalized.startsWith("---")) {
    return { frontmatter, body: normalized };
  }

  const endIndex = normalized.indexOf("\n---", 3);
  if (endIndex === -1) {
    return { frontmatter, body: normalized };
  }

  const frontmatterBlock = normalized.slice(4, endIndex);
  const body = normalized.slice(endIndex + 4).trim();

  let currentKey: string | null = null;
  let listItems: string[] = [];

  const flushList = (): void => {
    if (currentKey && listItems.length > 0) {
      frontmatter[currentKey] = [...listItems];
    }
    listItems = [];
    currentKey = null;
  };

  for (const rawLine of frontmatterBlock.split("\n")) {
    const line = rawLine.trimEnd();
    const listMatch = line.match(/^\s*-\s+(.*)$/);
    if (listMatch && currentKey) {
      listItems.push(listMatch[1]!.trim().replace(/^['"]|['"]$/g, ""));
      continue;
    }

    flushList();

    const match = line.match(/^([\w-]+):\s*(.*)$/);
    if (!match) continue;

    const key = match[1]!;
    const value = match[2] ?? "";
    if (!value.trim()) {
      currentKey = key;
      continue;
    }

    frontmatter[key] = parseScalar(value);
  }

  flushList();
  return { frontmatter, body };
}

export function frontmatterString(value: string | string[] | undefined): string | undefined {
  if (value === undefined) return undefined;
  return Array.isArray(value) ? value.join(", ") : value;
}

export function frontmatterStringList(value: string | string[] | undefined): string[] {
  if (value === undefined) return [];
  if (Array.isArray(value)) return value.map(String).filter(Boolean);
  return value
    .split(",")
    .map((part) => part.trim())
    .filter(Boolean);
}
