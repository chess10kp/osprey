// Project file listing for @ mentions, /explorer, and completions.

import { readdir } from "node:fs/promises";
import { join, relative } from "node:path";
import { loadGitignore } from "./gitignore.js";

const CHARS_PER_TOKEN = 4;
const TOKEN_WARN_THRESHOLD = 10_000;

export interface ListProjectFilesOptions {
  maxDepth?: number;
  maxFiles?: number;
  respectGitignore?: boolean;
}

/** Walk project tree and return paths relative to cwd (posix slashes). */
export async function listProjectFiles(
  cwd: string,
  options?: ListProjectFilesOptions,
): Promise<string[]> {
  const maxDepth = options?.maxDepth ?? 6;
  const maxFiles = options?.maxFiles ?? 3000;
  const respectGitignore = options?.respectGitignore ?? true;
  const ig = respectGitignore ? loadGitignore(cwd) : null;
  const out: string[] = [];

  async function walk(dir: string, depth: number, relPrefix: string): Promise<void> {
    if (depth > maxDepth || out.length >= maxFiles) return;

    let entries;
    try {
      entries = await readdir(dir, { withFileTypes: true });
    } catch {
      return;
    }

    entries.sort((a, b) => a.name.localeCompare(b.name));

    for (const entry of entries) {
      if (entry.name.startsWith(".") && entry.name !== ".env.example") continue;

      const rel = relPrefix ? `${relPrefix}/${entry.name}` : entry.name;
      if (ig?.ignores(rel) || (entry.isDirectory() && ig?.ignores(`${rel}/`))) {
        continue;
      }

      const abs = join(dir, entry.name);
      if (entry.isDirectory()) {
        await walk(abs, depth + 1, rel);
      } else if (entry.isFile()) {
        out.push(rel.split("\\").join("/"));
      }
      if (out.length >= maxFiles) break;
    }
  }

  await walk(cwd, 0, "");
  return out;
}

export function estimateTokensFromChars(chars: number): number {
  return Math.ceil(chars / CHARS_PER_TOKEN);
}

export function formatTokenEstimate(chars: number): string {
  const tokens = estimateTokensFromChars(chars);
  if (tokens >= TOKEN_WARN_THRESHOLD) {
    return `~${tokens.toLocaleString()} tokens (large selection)`;
  }
  return `~${tokens.toLocaleString()} tokens`;
}

/** Estimate total chars for selected file paths (reads files). */
export async function estimateSelectionChars(
  cwd: string,
  paths: string[],
): Promise<{ chars: number; tokens: number; warn: boolean }> {
  const { readFile } = await import("node:fs/promises");
  const { resolve, isAbsolute, normalize } = await import("node:path");

  let chars = 0;
  for (const p of paths) {
    const abs = isAbsolute(p) ? normalize(p) : resolve(cwd, p);
    try {
      const content = await readFile(abs, "utf-8");
      chars += content.length;
    } catch {
      chars += 100;
    }
  }

  const tokens = estimateTokensFromChars(chars);
  return { chars, tokens, warn: tokens >= TOKEN_WARN_THRESHOLD };
}
