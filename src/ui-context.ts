// Headless UI state for the Ink shell — dialogs, notifications, working indicator.

import type { AgentStore } from "./store.js";

export interface DialogRequest {
  id: string;
  kind: "select" | "confirm" | "input" | "editor";
  title: string;
  message?: string;
  options?: string[];
  placeholder?: string;
  prefill?: string;
  resolve: (value: unknown) => void;
}

export interface Notification {
  message: string;
  type: "info" | "warning" | "error" | "success";
  at: number;
}

export interface JackalUIState {
  notifications: Notification[];
  dialogs: DialogRequest[];
  statusEntries: Record<string, string>;
  workingMessage: string | null;
  workingVisible: boolean;
}

export class JackalUIContext {
  private _uiState: JackalUIState = {
    notifications: [],
    dialogs: [],
    statusEntries: {},
    workingMessage: null,
    workingVisible: false,
  };
  private _listeners = new Set<() => void>();

  constructor(_store: AgentStore) {
    void _store;
  }

  subscribe(listener: () => void): () => void {
    this._listeners.add(listener);
    return () => {
      this._listeners.delete(listener);
    };
  }

  getUIState(): JackalUIState {
    return this._uiState;
  }

  notify(message: string, type: "info" | "warning" | "error" | "success" = "info"): void {
    this._uiState = {
      ...this._uiState,
      notifications: [...this._uiState.notifications, { message, type, at: Date.now() }].slice(-50),
    };
    this._emit();
  }

  setStatus(key: string, text: string): void {
    this._uiState = {
      ...this._uiState,
      statusEntries: { ...this._uiState.statusEntries, [key]: text },
    };
    this._emit();
  }

  setWorkingMessage(message: string): void {
    this._uiState = { ...this._uiState, workingMessage: message };
    this._emit();
  }

  setWorkingVisible(visible: boolean): void {
    this._uiState = { ...this._uiState, workingVisible: visible };
    this._emit();
  }

  async select(title: string, options: string[], opts?: { timeout?: number; signal?: AbortSignal }): Promise<string | undefined> {
    const result = await this._dialog({ kind: "select", title, options }, opts);
    return result === undefined ? undefined : String(result);
  }

  async confirm(title: string, message: string, opts?: { timeout?: number; signal?: AbortSignal }): Promise<boolean> {
    const result = await this._dialog({ kind: "confirm", title, message }, opts);
    return result === true;
  }

  async input(title: string, placeholder: string, opts?: { timeout?: number; signal?: AbortSignal }): Promise<string> {
    const result = await this._dialog({ kind: "input", title, placeholder }, opts);
    return result === undefined ? "" : String(result);
  }

  async editor(title: string, prefill: string): Promise<string> {
    const result = await this._dialog({ kind: "editor", title, prefill }, undefined);
    return result === undefined ? "" : String(result);
  }

  resolveDialog(id: string, value: unknown): void {
    const dialog = this._uiState.dialogs.find((d) => d.id === id);
    if (!dialog) return;

    dialog.resolve(value);
    this._uiState = {
      ...this._uiState,
      dialogs: this._uiState.dialogs.filter((d) => d.id !== id),
    };
    this._emit();
  }

  /** Clear overlays and transient UI state (e.g. after /clear). */
  reset(): void {
    for (const dialog of this._uiState.dialogs) {
      try {
        dialog.resolve(undefined);
      } catch {
        /* swallow */
      }
    }
    this._uiState = {
      notifications: [],
      dialogs: [],
      statusEntries: {},
      workingMessage: null,
      workingVisible: false,
    };
    this._emit();
  }

  private _dialog(
    req: Omit<DialogRequest, "id" | "resolve">,
    opts?: { timeout?: number; signal?: AbortSignal },
  ): Promise<unknown> {
    return new Promise((resolve) => {
      const id = `dlg_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
      const timer = opts?.timeout
        ? setTimeout(() => this.resolveDialog(id, undefined), opts.timeout)
        : null;

      opts?.signal?.addEventListener("abort", () => this.resolveDialog(id, undefined), { once: true });

      const dialog: DialogRequest = {
        id,
        ...req,
        resolve: (value: unknown) => {
          if (timer) clearTimeout(timer);
          resolve(value);
        },
      };

      this._uiState = {
        ...this._uiState,
        dialogs: [...this._uiState.dialogs, dialog],
      };
      this._emit();
    });
  }

  private _emit(): void {
    for (const listener of this._listeners) {
      try {
        listener();
      } catch {
        /* swallow */
      }
    }
  }
}
