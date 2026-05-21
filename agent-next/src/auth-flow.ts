// ────────────────────────────────────────────────────────────────────────────
// Auth flow — login state machine for the Ink shell.
//
// Manages the multi-step auth flow: provider picker → OAuth/API-key login
// → model picker → ready. The Ink shell reads authFlow state and renders
// the appropriate overlay; user actions resolve pending promises.
// ────────────────────────────────────────────────────────────────────────────

export type AuthFlowStep =
  | { kind: "idle" }
  | { kind: "provider_picker"; providers: ProviderEntry[]; query: string }
  | { kind: "logging_in"; providerId: string; status: string }
  | { kind: "browser_auth"; providerId: string; url: string; instructions?: string }
  | { kind: "prompt"; providerId: string; message: string; placeholder?: string; pending: PromiseResolvers<string> }
  | { kind: "manual_code"; providerId: string; pending: PromiseResolvers<string> }
  | { kind: "select"; providerId: string; message: string; options: SelectOption[]; pending: PromiseResolvers<string | undefined> }
  | { kind: "api_key_input"; providerId: string; pending: PromiseResolvers<string | undefined> }
  | { kind: "logged_in"; providerId: string; nextStep: "model_picker" | "done" }
  | { kind: "model_picker"; models: ModelEntry[]; providerFilter?: string; query: string }
  | { kind: "error"; providerId?: string; message: string };

export interface ProviderEntry {
  id: string;
  displayName: string;
  authType: "oauth" | "api_key" | "env";
  configured: boolean;
  modelCount: number;
}

export interface ModelEntry {
  provider: string;
  modelId: string;
  displayName: string;
}

export interface SelectOption {
  id: string;
  label: string;
}

export interface PromiseResolvers<T> {
  resolve: (value: T) => void;
  reject: (reason?: any) => void;
}

export interface AuthFlowState {
  step: AuthFlowStep;
}

const INITIAL: AuthFlowState = { step: { kind: "idle" } };

export class AuthFlowStore {
  private _state: AuthFlowState = { ...INITIAL };
  private _listeners = new Set<() => void>();
  private _abortController: AbortController | null = null;

  get state(): AuthFlowState {
    return this._state;
  }

  subscribe(listener: () => void): () => void {
    this._listeners.add(listener);
    return () => { this._listeners.delete(listener); };
  }

  // ── Transitions ────────────────────────────────────────────────────

  openProviderPicker(providers: ProviderEntry[]): void {
    this._set({ kind: "provider_picker", providers, query: "" });
  }

  openModelPicker(models: ModelEntry[]): void {
    this._set({ kind: "model_picker", models, providerFilter: undefined, query: "" });
  }

  setLoggingIn(providerId: string, status: string): void {
    this._set({ kind: "logging_in", providerId, status });
  }

  setBrowserAuth(providerId: string, url: string, instructions?: string): void {
    this._set({ kind: "browser_auth", providerId, url, instructions });
  }

  setPrompt(providerId: string, message: string, placeholder: string, pending: PromiseResolvers<string>): void {
    this._set({ kind: "prompt", providerId, message, placeholder, pending });
  }

  setManualCode(providerId: string, pending: PromiseResolvers<string>): void {
    this._set({ kind: "manual_code", providerId, pending });
  }

  setSelect(providerId: string, message: string, options: SelectOption[], pending: PromiseResolvers<string | undefined>): void {
    this._set({ kind: "select", providerId, message, options, pending });
  }

  setApiKeyInput(providerId: string, pending: PromiseResolvers<string | undefined>): void {
    this._set({ kind: "api_key_input", providerId, pending });
  }

  setLoggedIn(providerId: string, nextStep: "model_picker" | "done"): void {
    this._set({ kind: "logged_in", providerId, nextStep });
  }

  setError(message: string, providerId?: string): void {
    this._set({ kind: "error", providerId, message });
  }

  setIdle(): void {
    this._cancelPending();
    this._set({ kind: "idle" });
  }

  updateQuery(query: string): void {
    const step = this._state.step;
    if (step.kind === "provider_picker") {
      this._set({ ...step, query });
    } else if (step.kind === "model_picker") {
      this._set({ ...step, query });
    }
  }

  updateProviderFilter(filter: string | undefined): void {
    const step = this._state.step;
    if (step.kind === "model_picker") {
      this._set({ ...step, providerFilter: filter });
    }
  }

  /** Get the abort signal for the current flow (for OAuth cancellation). */
  get signal(): AbortSignal {
    if (!this._abortController) {
      this._abortController = new AbortController();
    }
    return this._abortController.signal;
  }

  /** Cancel the in-flight auth flow. */
  cancel(): void {
    this._cancelPending();
    this._abortController?.abort();
    this._abortController = null;
    this._set({ kind: "idle" });
  }

  reset(): void {
    this._cancelPending();
    this._abortController?.abort();
    this._abortController = null;
    this._state = { ...INITIAL };
    this._emit();
  }

  // ── Internals ──────────────────────────────────────────────────────

  private _set(step: AuthFlowStep): void {
    this._state = { step };
    this._emit();
  }

  private _cancelPending(): void {
    const step = this._state.step;
    if (
      step.kind === "prompt" ||
      step.kind === "manual_code" ||
      step.kind === "select" ||
      step.kind === "api_key_input"
    ) {
      // Reject pending promises so the OAuth flow doesn't hang
      try {
        step.pending.reject(new Error("Auth flow cancelled"));
      } catch {
        // already resolved
      }
    }
  }

  private _emit(): void {
    for (const listener of this._listeners) {
      try { listener(); } catch { /* swallow */ }
    }
  }
}
