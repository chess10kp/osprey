// Subagent tool approval queue — parallel to main agent approval (nanocoder pattern).

export interface PendingSubagentApproval {
  toolCallId: string;
  toolName: string;
  params: Record<string, unknown>;
  subagentName: string;
}

export type PendingSubagentApprovalListener = (pending: PendingSubagentApproval | null) => void;

export class SubagentApprovalQueue {
  private _pending: PendingSubagentApproval | null = null;
  private _resolve: ((approved: boolean) => void) | null = null;

  constructor(private _onChange?: PendingSubagentApprovalListener) {}

  get pending(): PendingSubagentApproval | null {
    return this._pending;
  }

  requestApproval(
    toolCallId: string,
    toolName: string,
    params: Record<string, unknown>,
    subagentName: string,
  ): Promise<boolean> {
    if (this._resolve) {
      return Promise.resolve(false);
    }

    return new Promise((resolve) => {
      this._pending = { toolCallId, toolName, params, subagentName };
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
