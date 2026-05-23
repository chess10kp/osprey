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
  return errors
    .map((d) => `${d.file}:${d.line}:${d.column ?? 0}:${d.code ?? ""}:${d.message}`)
    .sort()
    .join("\n");
}
