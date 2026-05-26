import {
  bridgeFingerprintErrors,
  bridgeFormatDiagnostics,
} from "./jac-bridge.js";

export interface JacDiagnostic {
  file: string;
  line: number;
  column?: number;
  severity: "error" | "warning" | "info";
  code?: string;
  message: string;
  raw: string;
}

/** Deterministic fingerprint for no-progress detection in fix loops. */
export function fingerprintErrors(errors: JacDiagnostic[]): string {
  return bridgeFingerprintErrors(errors);
}

/** Format diagnostics for display. */
export function formatDiagnostics(diagnostics: JacDiagnostic[]): string {
  return bridgeFormatDiagnostics(diagnostics);
}
