// Jackal credential + model helpers (pi-ai).

import { existsSync, mkdirSync, readFileSync, writeFileSync, chmodSync } from "node:fs";
import { dirname, join } from "node:path";
import { homedir } from "node:os";
import {
  getEnvApiKey,
  getModels,
  getProviders,
  type Model,
  type Api,
} from "@earendil-works/pi-ai";
import {
  getOAuthApiKey,
  getOAuthProvider,
  getOAuthProviders,
  type OAuthCredentials,
  type OAuthLoginCallbacks,
  type OAuthProviderInterface,
} from "@earendil-works/pi-ai/oauth";

export type ApiKeyCredential = { type: "api_key"; key: string };
export type OAuthCredential = { type: "oauth" } & OAuthCredentials;
export type AuthCredential = ApiKeyCredential | OAuthCredential;
export type AuthStorageData = Record<string, AuthCredential>;

export type AuthStatus = {
  configured: boolean;
  source?: "stored" | "environment";
  label?: string;
};

function resolveAuthPath(): string {
  const agentDir =
    process.env.JACKAL_AGENT_DIR ||
    join(homedir(), ".jackal");
  return join(agentDir, "auth.json");
}

function loadAuthFile(path: string): AuthStorageData {
  if (!existsSync(path)) return {};
  try {
    const raw = readFileSync(path, "utf-8");
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === "object" ? parsed : {};
  } catch {
    return {};
  }
}

function saveAuthFile(path: string, data: AuthStorageData): void {
  const dir = dirname(path);
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true, mode: 0o700 });
  writeFileSync(path, JSON.stringify(data, null, 2) + "\n", "utf-8");
  chmodSync(path, 0o600);
}

export class JackalAuth {
  private _path: string;
  private _data: AuthStorageData;
  private _runtimeKeys = new Map<string, string>();

  private constructor(path: string, data: AuthStorageData) {
    this._path = path;
    this._data = data;
  }

  static create(authPath?: string): JackalAuth {
    const path = authPath ?? resolveAuthPath();
    return new JackalAuth(path, loadAuthFile(path));
  }

  reload(): void {
    this._data = loadAuthFile(this._path);
  }

  get(provider: string): AuthCredential | undefined {
    return this._data[provider];
  }

  set(provider: string, credential: AuthCredential): void {
    this._data = { ...this._data, [provider]: credential };
    saveAuthFile(this._path, this._data);
  }

  remove(provider: string): void {
    const next = { ...this._data };
    delete next[provider];
    this._data = next;
    saveAuthFile(this._path, this._data);
  }

  logout(provider: string): void {
    this.remove(provider);
  }

  has(provider: string): boolean {
    return provider in this._data;
  }

  getAll(): AuthStorageData {
    return { ...this._data };
  }

  getOAuthProviders(): OAuthProviderInterface[] {
    return getOAuthProviders();
  }

  getAuthStatus(provider: string): AuthStatus {
    if (this._runtimeKeys.has(provider)) {
      return { configured: true, source: "stored", label: "runtime override" };
    }
    if (this.has(provider)) {
      return { configured: true, source: "stored" };
    }
    const env = getEnvApiKey(provider);
    if (env) {
      return { configured: true, source: "environment", label: "env" };
    }
    return { configured: false };
  }

  hasAuth(provider: string): boolean {
    return this.getAuthStatus(provider).configured;
  }

  async getApiKey(providerId: string): Promise<string | undefined> {
    const runtime = this._runtimeKeys.get(providerId);
    if (runtime) return runtime;

    const stored = this.get(providerId);
    if (stored?.type === "api_key") return stored.key;

    if (stored?.type === "oauth") {
      const creds = await getOAuthApiKey(providerId, this._data as Record<string, OAuthCredentials>);
      if (creds?.apiKey) {
        if (creds.newCredentials) {
          this.set(providerId, { type: "oauth", ...creds.newCredentials });
        }
        return creds.apiKey;
      }
    }

    return getEnvApiKey(providerId);
  }

  async login(providerId: string, callbacks: OAuthLoginCallbacks): Promise<void> {
    const provider = getOAuthProvider(providerId);
    if (!provider) throw new Error(`Unknown OAuth provider: ${providerId}`);
    const credentials = await provider.login(callbacks);
    this.set(providerId, { type: "oauth", ...credentials });
  }
}

export class JackalModels {
  private _auth: JackalAuth;

  constructor(auth: JackalAuth) {
    this._auth = auth;
  }

  getAll(): Model<Api>[] {
    const out: Model<Api>[] = [];
    for (const provider of getProviders()) {
      out.push(...getModels(provider));
    }
    return out;
  }

  getAvailable(): Model<Api>[] {
    const models = this.getAll();
    return models.filter((m) => this._auth.hasAuth(m.provider));
  }

  find(provider: string, modelId: string): Model<Api> | undefined {
    return this.getAll().find((m) => m.provider === provider && m.id === modelId);
  }

  getProviderDisplayName(provider: string): string {
    const oauth = getOAuthProviders().find((p) => p.id === provider);
    return oauth?.name ?? provider;
  }
}
