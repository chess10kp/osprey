// Human-readable summaries and preview lines for tool approval UI in the Ink shell.
// Delegated to lib/jac/ui/_approval_display_toolchain.py via bridge.

import { bridgeFormatApprovalDisplay } from "../jac/jac-bridge.js";

export type ApprovalPreviewTone = "default" | "muted" | "added" | "removed" | "error" | "accent";

export interface ApprovalPreviewLine {
  text: string;
  tone?: ApprovalPreviewTone;
}

export interface ApprovalDisplay {
  headline: string;
  question: string;
  detailLines: string[];
  previewLines: ApprovalPreviewLine[];
}

export function formatApprovalDisplay(
  toolName: string,
  params: Record<string, unknown>,
  options?: { subagentName?: string },
): ApprovalDisplay {
  const raw = bridgeFormatApprovalDisplay(
    toolName,
    params,
    options?.subagentName,
  );
  return {
    headline: raw.headline,
    question: raw.question,
    detailLines: raw.detailLines,
    previewLines: raw.previewLines.map((l: { text: string; tone?: string }) => ({
      text: l.text,
      tone: (l.tone ?? "default") as ApprovalPreviewTone,
    })),
  };
}
