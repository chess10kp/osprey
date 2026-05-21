// ────────────────────────────────────────────────────────────────────────────
// Auth actions — imperative actions that drive AuthStorage/ModelRegistry
// through the AuthFlowStore state machine.
//
// The Ink shell calls these on user interaction. Each action translates
// Pi's auth APIs into state machine transitions.
// ────────────────────────────────────────────────────────────────────────────

import type { AuthStorage } from "@earendil-works/pi-coding-agent";
import type { ModelRegistry } from "@earendil-works/pi-coding-agent";
import { AuthFlowStore, type ProviderEntry, type ModelEntry } from "./auth-flow.js";

export class AuthActions {
  private _authStorage: AuthStorage;
  private _modelRegistry: ModelRegistry;
  private _flow: AuthFlowStore;
  private _onLoginComplete?: () => void;

  constructor(
    authStorage: AuthStorage,
    modelRegistry: ModelRegistry,
    flow: AuthFlowStore,
    onLoginComplete?: () => void,
  ) {
    this._authStorage = authStorage;
    this._modelRegistry = modelRegistry;
    this._flow = flow;
    this._onLoginComplete = onLoginComplete;
  }

  get flow(): AuthFlowStore {
    return this._flow;
  }

  // ── Public actions ─────────────────────────────────────────────────

  /** Open the provider picker. */
  login(): void {
    const providers = this._listProviders();
    this._flow.openProviderPicker(providers);
  }

  /** Login with a specific provider (skip picker). */
  loginWith(providerId: string): void {
    const providers = this._listProviders();
    const provider = providers.find((p) => p.id === providerId);
    if (!provider) {
      this._flow.setError(`Unknown provider: ${providerId}`);
      return;
    }

    if (provider.authType === "api_key" || provider.authType === "env") {
      this._startApiKeyLogin(providerId);
    } else {
      this._startOAuthLogin(providerId);
    }
  }

  /** Logout from a provider. */
  logout(providerId: string): void {
    this._authStorage.logout(providerId);
  }

  /** Cancel the in-flight auth flow. */
  cancelLogin(): void {
    this._flow.cancel();
  }

  /** Resolve an in-flight prompt (user typed input). */
  submitAuthPrompt(value: string): void {
    const step = this._flow.state.step;
    if (step.kind === "prompt") {
      step.pending.resolve(value);
    } else if (step.kind === "manual_code") {
      step.pending.resolve(value);
    }
  }

  /** Resolve an in-flight select (user picked an option). */
  submitAuthSelect(optionId: string): void {
    const step = this._flow.state.step;
    if (step.kind === "select") {
      step.pending.resolve(optionId || undefined);
    }
  }

  /** Resolve an in-flight API key input. */
  submitApiKey(key: string): void {
    const step = this._flow.state.step;
    if (step.kind === "api_key_input") {
      step.pending.resolve(key || undefined);
    }
  }

  /** Select a model (from model picker or programmatically). */
  selectModel(provider: string, modelId: string): void {
    // This is a hook for the host to apply the model selection.
    // The actual session.setModel() is called by the adapter.
    this._flow.setIdle();
    this._onLoginComplete?.();
  }

  /** List providers (snapshot). */
  listProviders(): ProviderEntry[] {
    return this._listProviders();
  }

  /** List models (snapshot). */
  listModels(provider?: string): ModelEntry[] {
    return this._listModels(provider);
  }

  // ── Internals ──────────────────────────────────────────────────────

  private _listProviders(): ProviderEntry[] {
    const entries: ProviderEntry[] = [];

    // OAuth providers
    for (const oauth of this._authStorage.getOAuthProviders()) {
      const status = this._authStorage.getAuthStatus(oauth.id);
      const models = this._listModels(oauth.id);
      entries.push({
        id: oauth.id,
        displayName: oauth.name,
        authType: "oauth",
        configured: status.configured,
        modelCount: models.length,
      });
    }

    // API-key providers (from models that aren't OAuth)
    const oauthIds = new Set(entries.map((e) => e.id));
    const seenProviders = new Set<string>();
    for (const model of (this._modelRegistry as any).models ?? []) {
      if (oauthIds.has(model.provider) || seenProviders.has(model.provider)) continue;
      seenProviders.add(model.provider);

      const status = this._authStorage.getAuthStatus(model.provider);
      const models = this._listModels(model.provider);
      const displayName = this._modelRegistry.getProviderDisplayName(model.provider);

      entries.push({
        id: model.provider,
        displayName,
        authType: status.source === "environment" ? "env" : "api_key",
        configured: status.configured,
        modelCount: models.length,
      });
    }

    return entries;
  }

  private _listModels(provider?: string): ModelEntry[] {
    const models: ModelEntry[] = [];
    for (const model of (this._modelRegistry as any).models ?? []) {
      if (provider && model.provider !== provider) continue;
      models.push({
        provider: model.provider,
        modelId: model.id,
        displayName: `${model.provider}/${model.id}`,
      });
    }
    return models;
  }

  private async _startOAuthLogin(providerId: string): Promise<void> {
    this._flow.setLoggingIn(providerId, "Starting OAuth flow...");

    try {
      await this._authStorage.login(providerId, {
        signal: this._flow.signal,
        onAuth: (info) => {
          this._flow.setBrowserAuth(providerId, info.url, info.instructions);
        },
        onPrompt: (p) =>
          new Promise((resolve, reject) => {
            this._flow.setPrompt(providerId, p.message, p.placeholder ?? "", { resolve, reject });
          }),
        onManualCodeInput: () =>
          new Promise((resolve, reject) => {
            this._flow.setManualCode(providerId, { resolve, reject });
          }),
        onSelect: (p) =>
          new Promise((resolve, reject) => {
            this._flow.setSelect(providerId, p.message, p.options.map((o: any) => ({ id: o.id, label: o.label })), { resolve, reject });
          }),
        onProgress: (msg) => {
          this._flow.setLoggingIn(providerId, msg);
        },
      });

      // Login succeeded
      this._flow.setLoggedIn(providerId, "model_picker");

      // Auto-open model picker
      const models = this._listModels(providerId);
      if (models.length > 0) {
        this._flow.openModelPicker(models);
      } else {
        this._flow.setIdle();
        this._onLoginComplete?.();
      }
    } catch (err: any) {
      if (this._flow.signal.aborted) {
        this._flow.setIdle();
        return;
      }
      this._flow.setError(err?.message || String(err), providerId);
    }
  }

  private _startApiKeyLogin(providerId: string): void {
    const pending: { resolve: (value: string | undefined) => void; reject: (reason?: any) => void } = {
      resolve: () => {},
      reject: () => {},
    };
    const promise = new Promise<string | undefined>((resolve, reject) => {
      pending.resolve = resolve;
      pending.reject = reject;
    });

    this._flow.setApiKeyInput(providerId, pending);

    promise.then((key) => {
      if (!key) {
        this._flow.setIdle();
        return;
      }

      this._authStorage.set(providerId, { type: "api_key", key });
      this._flow.setLoggedIn(providerId, "model_picker");

      const models = this._listModels(providerId);
      if (models.length > 0) {
        this._flow.openModelPicker(models);
      } else {
        this._flow.setIdle();
        this._onLoginComplete?.();
      }
    }).catch(() => {
      this._flow.setIdle();
    });
  }
}
