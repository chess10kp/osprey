// Project file listing for @ mentions, /explorer, and completions.

import {
  bridgeEstimateSelectionChars,
  bridgeListProjectFiles,
} from "../jac/jac-bridge.js";

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
  return bridgeListProjectFiles(cwd, options);
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
  return bridgeEstimateSelectionChars(cwd, paths);
}
