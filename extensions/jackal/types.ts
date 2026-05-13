// ────────────────────────────────────────────────────────────────────────────
// Shared types, state singleton, and utility functions for the Jackal extension.
// No Pi SDK imports — purely domain types.
// ────────────────────────────────────────────────────────────────────────────

export interface JacDiagnostic {
  file: string;
  line: number;
  column?: number;
  severity: "error" | "warning" | "info";
  code?: string;
  message: string;
  raw: string;
}

export interface JacPlanStep {
  step: number;
  text: string;
  completed: boolean;
}

export interface JackalState {
  /** Most-recently written/edited .jac file in this session. */
  workingFile?: string;
  /** Per-file edit counter for the attempt cap. */
  attempts: Map<string, number>;
  /** Per-file fingerprint of the last reported error set (for no-progress detection). */
  lastErrorFingerprint: Map<string, string>;
  /** .jac files written/edited during the current agent run, pending end-of-turn check. */
  pendingCheckFiles: Set<string>;
  /** Plan mode state. */
  planMode?: {
    enabled: boolean;
    executing: boolean;
    todos: JacPlanStep[];
  };
}

/** Singleton session state. */
export const state: JackalState = {
  attempts: new Map(),
  lastErrorFingerprint: new Map(),
  pendingCheckFiles: new Set(),
};

/** Produce a deterministic fingerprint for a set of diagnostics (used for no-progress detection). */
export function fingerprintErrors(errors: JacDiagnostic[]): string {
  return errors
    .map((d) => `${d.file}:${d.line}:${d.column ?? 0}:${d.code ?? ""}:${d.message}`)
    .sort()
    .join("\n");
}

/** Per-process runtime override for the jac-verbose flag. */
export let verboseOverride: boolean | undefined;

export function setVerboseOverride(value: boolean | undefined): void {
  verboseOverride = value;
}

export function getVerboseOverride(): boolean | undefined {
  return verboseOverride;
}
