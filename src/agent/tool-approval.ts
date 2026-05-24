// Tool approval queue — blocks agent tool execution until user approves or rejects.

import { formatApprovalDisplay } from "../ui/approval-display.js";

export interface PendingApproval {
  toolCallId: string;
  toolName: string;
  params: Record<string, unknown>;
  /** Short label for the approval overlay */
  headline?: string;
  /** Prompt above the Yes/No selector */
  question?: string;
  /** Multi-line argument preview (legacy / plain) */
  detailLines?: string[];
  /** Rich preview lines with tone hints for Ink */
  previewLines?: import("../ui/approval-display.js").ApprovalPreviewLine[];
}

export type PendingApprovalListener = (pending: PendingApproval | null) => void;

export class ToolApprovalQueue {
  private _pending: PendingApproval | null = null;
  private _resolve: ((approved: boolean) => void) | null = null;

  constructor(private _onChange?: PendingApprovalListener) {}

  get pending(): PendingApproval | null {
    return this._pending;
  }

  /** Wait for user decision. Resolves true when approved, false when rejected. */
  requestApproval(
    toolCallId: string,
    toolName: string,
    params: Record<string, unknown>,
  ): Promise<boolean> {
    if (this._resolve) {
      return Promise.resolve(false);
    }

    return new Promise((resolve) => {
      const display = formatApprovalDisplay(toolName, params);
      this._pending = {
        toolCallId,
        toolName,
        params,
        headline: display.headline,
        question: display.question,
        detailLines: display.detailLines,
        previewLines: display.previewLines,
      };
      this._resolve = resolve;
      this._onChange?.(this._pending);
    });
  }

  approve(): boolean {
    if (!this._resolve || !this._pending) return false;
    this._resolve(true);
    this._clear();
    return true;
  }

  reject(): boolean {
    if (!this._resolve || !this._pending) return false;
    this._resolve(false);
    this._clear();
    return true;
  }

  /** Drop a pending request without resolving (e.g. session abort). */
  cancel(): void {
    if (this._resolve) {
      this._resolve(false);
    }
    this._clear();
  }

  private _clear(): void {
    this._pending = null;
    this._resolve = null;
    this._onChange?.(null);
  }
}
