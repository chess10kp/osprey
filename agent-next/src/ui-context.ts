// ────────────────────────────────────────────────────────────────────────────
// Headless UI context for the jac-ink shell — implements ExtensionUIContext.
//
// This provides the "supported" subset of Pi's extension UI surface
// using the AgentStore as the backing state. Extensions that call
// unsupported methods (custom factory, setFooter, etc.) get a structured
// error instead of a silent crash.
// ────────────────────────────────────────────────────────────────────────────

import type { AgentStore } from "./store.js";

export interface DialogRequest {
  id: string;
  kind: "select" | "confirm" | "input" | "editor";
  title: string;
  message?: string;
  options?: string[];
  placeholder?: string;
  prefill?: string;
  resolve: (value: any) => void;
}

export interface Notification {
  message: string;
  type: "info" | "warning" | "error" | "success";
  at: number;
}

export interface InkUIState {
  notifications: Notification[];
  dialogs: DialogRequest[];
  statusEntries: Record<string, string>;
  workingMessage: string | null;
  workingVisible: boolean;
}

/**
 * Minimal ExtensionUIContext implementation backed by an AgentStore.
 * Extensions call these methods; the Ink shell reads the state and renders.
 */
export class InkExtensionUIContext {
  private _store: AgentStore;
  private _uiState: InkUIState = {
    notifications: [],
    dialogs: [],
    statusEntries: {},
    workingMessage: null,
    workingVisible: false,
  };
  private _listeners = new Set<() => void>();

  constructor(store: AgentStore) {
    this._store = store;
  }

  /** Subscribe to UI state changes (dialogs, notifications, etc.). */
  subscribe(listener: () => void): () => void {
    this._listeners.add(listener);
    return () => { this._listeners.delete(listener); };
  }

  /** Get current UI state snapshot. */
  getUIState(): InkUIState {
    return this._uiState;
  }

  // ──── Supported methods ─────────────────────────────────────────────

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

  setTitle(title: string): void {
    try {
      process.stdout.write(`\x1b]0;${title}\x07`);
    } catch {
      // ignore — not all terminals support OSC
    }
  }

  setWorkingMessage(message: string): void {
    this._uiState = { ...this._uiState, workingMessage: message };
    this._emit();
  }

  setWorkingVisible(visible: boolean): void {
    this._uiState = { ...this._uiState, workingVisible: visible };
    this._emit();
  }

  setWorkingIndicator(_opts: any): void {
    // Accept the call, no-op for now
  }

  setHiddenThinkingLabel(_label: string): void {
    // Accept the call, no-op
  }

  setWidget(_key: string, contentOrFactory: any, _options?: any): void {
    if (typeof contentOrFactory === "function") {
      this._unsupported("setWidget(factory)");
      return;
    }
    // String/array widgets — accept but no rendering yet
  }

  pasteToEditor(_text: string): void {
    // No editor bound yet
  }

  setEditorText(_text: string): void {
    // No editor bound yet
  }

  getEditorText(): string {
    return "";
  }

  addAutocompleteProvider(_factory: any): () => void {
    return () => {};
  }

  // ──── Dialog methods (return Promises resolved by the Ink shell) ────

  async select(title: string, options: string[], opts?: any): Promise<string | undefined> {
    return this._dialog({ kind: "select", title, options }, opts);
  }

  async confirm(title: string, message: string, opts?: any): Promise<boolean> {
    const result = await this._dialog({ kind: "confirm", title, message }, opts);
    return result === true;
  }

  async input(title: string, placeholder: string, opts?: any): Promise<string> {
    const result = await this._dialog({ kind: "input", title, placeholder }, opts);
    return result ?? "";
  }

  async editor(title: string, prefill: string): Promise<string> {
    const result = await this._dialog({ kind: "editor", title, prefill }, undefined);
    return result ?? "";
  }

  // ──── Theme stubs (return safe defaults) ────────────────────────────

  get theme(): any {
    return {
      colors: {},
      fg: (s: string) => s,
      bg: (_s: string) => "",
      dim: (s: string) => s,
      bold: (s: string) => s,
      red: (s: string) => s,
      green: (s: string) => s,
      yellow: (s: string) => s,
      blue: (s: string) => s,
      magenta: (s: string) => s,
      cyan: (s: string) => s,
    };
  }

  getAllThemes(): any[] {
    return [];
  }

  getTheme(_name: string): any {
    return undefined;
  }

  setTheme(_theme: any): void {
    // No-op
  }

  getToolsExpanded(): boolean {
    return false;
  }

  setToolsExpanded(_v: boolean): void {
    // No-op
  }

  onTerminalInput(_handler: any): () => void {
    return () => {};
  }

  // ──── Unsupported (degraded) ────────────────────────────────────────

  custom(_factory: any, _options?: any): any {
    return this._unsupported("custom(component factory)");
  }

  setEditorComponent(_factory: any): void {
    this._unsupported("setEditorComponent(component factory)");
  }

  getEditorComponent(): any {
    return undefined;
  }

  setFooter(_factory: any): void {
    this._unsupported("setFooter(component factory)");
  }

  setHeader(_factory: any): void {
    this._unsupported("setHeader(component factory)");
  }

  // ──── Internals ─────────────────────────────────────────────────────

  private _dialog(req: Omit<DialogRequest, "id" | "resolve">, opts: any): Promise<any> {
    return new Promise((resolve) => {
      const id = `dlg_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
      const timer = opts?.timeout
        ? setTimeout(() => this.resolveDialog(id, undefined), opts.timeout)
        : null;

      opts?.signal?.addEventListener("abort", () => this.resolveDialog(id, undefined), { once: true });

      const dialog: DialogRequest = {
        id,
        ...req,
        resolve: (value: any) => {
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

  /** Resolve a pending dialog by ID (called by the Ink shell on user action). */
  resolveDialog(id: string, value: any): void {
    const dialog = this._uiState.dialogs.find((d) => d.id === id);
    if (!dialog) return;

    dialog.resolve(value);
    this._uiState = {
      ...this._uiState,
      dialogs: this._uiState.dialogs.filter((d) => d.id !== id),
    };
    this._emit();
  }

  private _unsupported(call: string): undefined {
    this.notify(
      `jac-ink does not support ExtensionUIContext.${call}.`,
      "warning",
    );
    return undefined;
  }

  private _emit(): void {
    for (const listener of this._listeners) {
      try {
        listener();
      } catch {
        // swallow
      }
    }
  }
}
