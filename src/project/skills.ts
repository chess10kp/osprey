// Agent Skills loader — delegates to Python toolchain via bridge.
//
// All discovery, loading, formatting, and expansion logic lives in
// lib/jac/project/_skills_toolchain.py. This file re-exports typed wrappers
// for backward compatibility with the rest of the TypeScript codebase.

import {
  bridgeLoadSkillsFromDir,
  bridgeLoadJackalSkills,
  bridgeFormatSkillsForPrompt,
  bridgeAppendSkillsToPrompt,
  bridgeExpandSkillCommand,
  bridgeLoadSkillByDir,
  bridgeSkillReadAllowlist,
  type BridgeSkill,
  type BridgeSkillDiagnostic,
  type BridgeLoadSkillsResult,
} from "../jac/jac-bridge.js";

// ── Re-exported types (same shape as before) ─────────────────────────────

export type SkillSource = "builtin" | "user" | "project" | "path";

export interface Skill {
  name: string;
  description: string;
  filePath: string;
  baseDir: string;
  source: SkillSource;
  disableModelInvocation: boolean;
}

export interface SkillDiagnostic {
  type: "warning" | "collision";
  message: string;
  path: string;
  collision?: {
    name: string;
    winnerPath: string;
    loserPath: string;
  };
}

export interface LoadSkillsResult {
  skills: Skill[];
  diagnostics: SkillDiagnostic[];
}

export interface LoadSkillsFromDirOptions {
  dir: string;
  source: SkillSource;
}

export interface LoadJackalSkillsOptions {
  cwd?: string;
  packageRoot?: string;
  /** Global skills root (default ~/.jackal). */
  agentDir?: string;
  skillPaths?: string[];
  includeDefaults?: boolean;
}

// ── Bridge result → typed result conversion ────────────────────────────────

function toSkill(b: BridgeSkill): Skill {
  return {
    name: b.name,
    description: b.description,
    filePath: b.filePath,
    baseDir: b.baseDir,
    source: b.source as SkillSource,
    disableModelInvocation: b.disableModelInvocation,
  };
}

function toDiagnostic(b: BridgeSkillDiagnostic): SkillDiagnostic {
  return {
    type: b.type,
    message: b.message,
    path: b.path,
    collision: b.collision,
  };
}

function toResult(b: BridgeLoadSkillsResult): LoadSkillsResult {
  return {
    skills: b.skills.map(toSkill),
    diagnostics: b.diagnostics.map(toDiagnostic),
  };
}

function toBridgeSkill(s: Skill): BridgeSkill {
  return {
    name: s.name,
    description: s.description,
    filePath: s.filePath,
    baseDir: s.baseDir,
    source: s.source,
    disableModelInvocation: s.disableModelInvocation,
  };
}

// ── Public API — delegates to bridge ─────────────────────────────────────

export function loadSkillsFromDir(options: LoadSkillsFromDirOptions): LoadSkillsResult {
  return toResult(bridgeLoadSkillsFromDir(options.dir, options.source));
}

export function loadJackalSkills(options: LoadJackalSkillsOptions = {}): LoadSkillsResult {
  return toResult(bridgeLoadJackalSkills(options));
}

export function formatSkillsForPrompt(skills: Skill[]): string {
  return bridgeFormatSkillsForPrompt(skills.map(toBridgeSkill));
}

export function expandSkillCommand(text: string, skills: Skill[]): string {
  return bridgeExpandSkillCommand(text, skills.map(toBridgeSkill));
}

export function appendSkillsToPrompt(systemPrompt: string, skills: Skill[]): string {
  return bridgeAppendSkillsToPrompt(systemPrompt, skills.map(toBridgeSkill));
}

export function loadSkillByDir(dirName: string, packageRoot?: string): string {
  return bridgeLoadSkillByDir(dirName, packageRoot);
}

export function skillReadAllowlist(skills: Skill[]): {
  files: Set<string>;
  roots: string[];
} {
  const result = bridgeSkillReadAllowlist(skills.map(toBridgeSkill));
  return {
    files: new Set(result.files),
    roots: result.roots,
  };
}
