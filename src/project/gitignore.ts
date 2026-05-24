// Load .gitignore patterns for project file listing.

import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import ignore, { type Ignore } from "ignore";

const DEFAULT_IGNORE_DIRS = [
  "node_modules",
  ".cache",
  "dist",
  "build",
  "out",
  ".next",
  ".nuxt",
  "__pycache__",
  ".pytest_cache",
  "target",
  "coverage",
  ".git",
  ".svn",
  ".hg",
  ".jac",
  ".jackal",
];

/** Load ignore rules from defaults and optional `.gitignore` in cwd. */
export function loadGitignore(cwd: string): Ignore {
  const ig = ignore();
  ig.add(DEFAULT_IGNORE_DIRS);

  const gitignorePath = join(cwd, ".gitignore");
  if (existsSync(gitignorePath)) {
    try {
      ig.add(readFileSync(gitignorePath, "utf-8"));
    } catch {
      // keep defaults only
    }
  }

  return ig;
}
