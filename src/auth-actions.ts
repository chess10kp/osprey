// Auth actions — drives JackalAuth through the AuthFlowStore state machine.

import type { JackalAuth, JackalModels } from "./runtime/auth.js";
import { AuthFlowStore, type ProviderEntry, type ModelEntry } from "./auth-flow.js";

export class AuthActions {
  private _auth: JackalAuth;
  private _models: JackalModels;
  private _flow: AuthFlowStore;
  private _onLoginComplete?: () => void;

  constructor(
    auth: JackalAuth,
    models: JackalModels,
    flow: AuthFlowStore,
    onLoginComplete?: () => void,
  ) {
    this._auth = auth;
    this._models = models;
    this._flow = flow;
    this._onLoginComplete = onLoginComplete;
  }

  get flow(): AuthFlowStore {
    return this._flow;
  }

  login(): void {
    const providers = this._listProviders();
    this._flow.openProviderPicker(providers);
  }

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

  logout(providerId: string): void {
    this._auth.logout(providerId);
  }

  cancelLogin(): void {
    this._flow.cancel();
  }

  submitAuthPrompt(value: string): void {
    const step = this._flow.state.step;
    if (step.kind === "prompt") {
      step.pending.resolve(value);
    } else if (step.kind === "manual_code") {
      step.pending.resolve(value);
    }
  }

  submitAuthSelect(optionId: string): void {
    const step = this._flow.state.step;
    if (step.kind === "select") {
      step.pending.resolve(optionId || undefined);
    }
  }

  submitApiKey(key: string): void {
    const step = this._flow.state.step;
    if (step.kind === "api_key_input") {
      step.pending.resolve(key || undefined);
    }
  }

  selectModel(_provider: string, _modelId: string): void {
    this._flow.setIdle();
    this._onLoginComplete?.();
  }

  listProviders(): ProviderEntry[] {
    return this._listProviders();
  }

  listModels(provider?: string): ModelEntry[] {
    return this._listModels(provider);
  }

  private _listProviders(): ProviderEntry[] {
    const entries: ProviderEntry[] = [];

    for (const oauth of this._auth.getOAuthProviders()) {
      const status = this._auth.getAuthStatus(oauth.id);
      const modelList = this._listModels(oauth.id);
      entries.push({
        id: oauth.id,
        displayName: oauth.name,
        authType: "oauth",
        configured: status.configured,
        modelCount: modelList.length,
      });
    }

    const oauthIds = new Set(entries.map((e) => e.id));
    const seenProviders = new Set<string>();
    for (const model of this._models.getAll()) {
      if (oauthIds.has(model.provider) || seenProviders.has(model.provider)) continue;
      seenProviders.add(model.provider);

      const status = this._auth.getAuthStatus(model.provider);
      const modelList = this._listModels(model.provider);

      entries.push({
        id: model.provider,
        displayName: this._models.getProviderDisplayName(model.provider),
        authType: status.source === "environment" ? "env" : "api_key",
        configured: status.configured,
        modelCount: modelList.length,
      });
    }

    return entries;
  }

  private _listModels(provider?: string): ModelEntry[] {
    const models: ModelEntry[] = [];
    for (const model of this._models.getAll()) {
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
      await this._auth.login(providerId, {
        signal: this._flow.signal,
        onAuth: (info) => {
          this._flow.setBrowserAuth(providerId, info.url, info.instructions);
        },
        onPrompt: (p) =>
          new Promise((resolve, reject) => {
            this._flow.setPrompt(providerId, p.message, p.placeholder ?? "", {
              resolve,
              reject,
            });
          }),
        onManualCodeInput: () =>
          new Promise((resolve, reject) => {
            this._flow.setManualCode(providerId, { resolve, reject });
          }),
        onSelect: (p) =>
          new Promise((resolve, reject) => {
            this._flow.setSelect(
              providerId,
              p.message,
              p.options.map((o) => ({ id: o.id, label: o.label })),
              { resolve, reject },
            );
          }),
        onProgress: (msg) => {
          this._flow.setLoggingIn(providerId, msg);
        },
      });

      this._flow.setLoggedIn(providerId, "model_picker");

      const modelList = this._listModels(providerId);
      if (modelList.length > 0) {
        this._flow.openModelPicker(modelList);
      } else {
        this._flow.setIdle();
        this._onLoginComplete?.();
      }
    } catch (err: unknown) {
      if (this._flow.signal.aborted) {
        this._flow.setIdle();
        return;
      }
      const message = err instanceof Error ? err.message : String(err);
      this._flow.setError(message, providerId);
    }
  }

  private _startApiKeyLogin(providerId: string): void {
    const pending: {
      resolve: (value: string | undefined) => void;
      reject: (reason?: unknown) => void;
    } = {
      resolve: () => {},
      reject: () => {},
    };
    const promise = new Promise<string | undefined>((resolve, reject) => {
      pending.resolve = resolve;
      pending.reject = reject;
    });

    this._flow.setApiKeyInput(providerId, pending);

    promise
      .then((key) => {
        if (!key) {
          this._flow.setIdle();
          return;
        }

        this._auth.set(providerId, { type: "api_key", key });
        this._flow.setLoggedIn(providerId, "model_picker");

        const modelList = this._listModels(providerId);
        if (modelList.length > 0) {
          this._flow.openModelPicker(modelList);
        } else {
          this._flow.setIdle();
          this._onLoginComplete?.();
        }
      })
      .catch(() => {
        this._flow.setIdle();
      });
  }
}
