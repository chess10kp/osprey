// Project initializer — delegates to Python toolchain via bridge.
//
// All analysis and generation logic lives in lib/jac/project/_project_init_toolchain.py.
// This file re-exports typed wrappers for backward compatibility.

import { join, resolve } from "node:path";
import {
  bridgeAnalyzeProject,
  bridgeGenerateAgentsMd,
  bridgeRunProjectInit,
  type BridgeProjectInfo,
} from "../jac/jac-bridge.js";

// ── Re-exported types ─────────────────────────────────────────────────────

export type ProjectType =
  | "fullstack"
  | "api"
  | "client-only"
  | "library"
  | "mixed"
  | "non-jac";

export interface ProjectInfo {
  projectName: string;
  description: string;
  hasJacToml: boolean;
  jacTomlEntry: string | null;
  jacVersion: string | null;
  pythonVersion: string | null;
  jacFiles: string[];
  pythonFiles: string[];
  hasVenv: boolean;
  hasGit: boolean;
  hasTests: boolean;
  hasReadme: boolean;
  hasAgentsMd: boolean;
  hasJackalConfig: boolean;
  npmDeps: string[];
  projectType: ProjectType;
}

// ── Bridge → typed conversion ─────────────────────────────────────────────

function toProjectInfo(b: BridgeProjectInfo): ProjectInfo {
  return {
    ...b,
    projectType: b.projectType as ProjectType,
  };
}

// ── Public API — delegates to bridge ─────────────────────────────────────

/**
 * Analyze a project directory and return structured info.
 */
export function analyzeProject(cwd: string): ProjectInfo {
  return toProjectInfo(bridgeAnalyzeProject(cwd));
}

/**
 * Generate an AGENTS.md template from project analysis.
 */
export function generateAgentsMd(info: ProjectInfo): string {
  return bridgeGenerateAgentsMd(info as unknown as BridgeProjectInfo);
}

/**
 * Run `/init` — analyze project and write/update AGENTS.md.
 */
export async function runProjectInit(
  cwd: string,
  options?: { force?: boolean; lean?: boolean },
): Promise<{ written: boolean; path: string; content: string }> {
  return bridgeRunProjectInit(cwd, options);
}
