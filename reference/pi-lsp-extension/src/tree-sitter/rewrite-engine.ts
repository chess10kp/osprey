/**
 * Rewrite Engine — apply structural replacements using matched patterns.
 *
 * Takes search matches and a replacement template with metavariable references,
 * substitutes captured values, and applies the text changes.
 */

import { readFile, writeFile } from "node:fs/promises";
import type { SearchMatch } from "./search-engine.js";

// ── Result types ────────────────────────────────────────────────────────────

export interface RewriteChange {
  file: string;
  line: number;
  column: number;
  before: string;
  after: string;
}

export interface RewriteResult {
  changes: RewriteChange[];
  filesModified: number;
}

// ── Replacement template substitution ───────────────────────────────────────

const METAVAR_REF_RE = /\$\$\$([A-Z_][A-Z0-9_]*)|\$([A-Z_][A-Z0-9_]*)/g;

/**
 * Substitute metavariable references in a replacement template with captured values.
 */
export function substituteCaptures(
  template: string,
  captures: Record<string, string>,
): string {
  return template.replace(METAVAR_REF_RE, (match, variadicName, singleName) => {
    const name = variadicName ?? singleName;
    if (name in captures) return captures[name];
    return match; // Leave unmatched references as-is
  });
}

/**
 * If the original matched text ends with a semicolon (possibly preceded by whitespace)
 * and the replacement doesn't, append the semicolon. This preserves statement terminators
 * that are part of the AST node but not part of the pattern/replacement.
 */
function preserveTrailingSemicolon(original: string, replacement: string): string {
  const trailingMatch = original.match(/(\s*;)\s*$/);
  if (trailingMatch && !replacement.trimEnd().endsWith(";")) {
    return replacement + trailingMatch[1];
  }
  return replacement;
}

// ── Rewrite application ─────────────────────────────────────────────────────

/**
 * Compute rewrite changes from matches and a replacement template.
 * Returns the list of changes without applying them.
 */
export function computeRewrites(
  matches: SearchMatch[],
  replacementTemplate: string,
): RewriteChange[] {
  return matches.map((m) => {
    const raw = substituteCaptures(replacementTemplate, m.captures);
    const after = preserveTrailingSemicolon(m.matchedText, raw);
    return {
      file: m.file,
      line: m.line,
      column: m.column,
      before: m.matchedText,
      after,
    };
  });
}

/**
 * Apply rewrite changes to files. Modifies files in-place.
 * Applies changes bottom-up (last offset first) within each file to preserve byte offsets.
 */
export async function applyRewrites(
  matches: SearchMatch[],
  replacementTemplate: string,
): Promise<RewriteResult> {
  // Group matches by file
  const byFile = new Map<string, SearchMatch[]>();
  for (const m of matches) {
    const existing = byFile.get(m.file);
    if (existing) {
      existing.push(m);
    } else {
      byFile.set(m.file, [m]);
    }
  }

  const changes: RewriteChange[] = [];
  let filesModified = 0;

  for (const [file, fileMatches] of byFile) {
    // Sort by startIndex descending — apply from bottom to top
    const sorted = [...fileMatches].sort((a, b) => b.startIndex - a.startIndex);

    let content = await readFile(file, "utf-8");
    let modified = false;

    for (const m of sorted) {
      const raw = substituteCaptures(replacementTemplate, m.captures);
      const replacement = preserveTrailingSemicolon(m.matchedText, raw);
      if (replacement !== m.matchedText) {
        content =
          content.slice(0, m.startIndex) +
          replacement +
          content.slice(m.endIndex);
        modified = true;
      }
      changes.push({
        file,
        line: m.line,
        column: m.column,
        before: m.matchedText,
        after: replacement,
      });
    }

    if (modified) {
      await writeFile(file, content, "utf-8");
      filesModified++;
    }
  }

  // Reverse so changes appear top-to-bottom
  changes.reverse();

  return { changes, filesModified };
}
