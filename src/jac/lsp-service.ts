// Jac LSP service — starts `jac lsp` on session boot and exposes LSP-backed helpers.

import { existsSync, readFileSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";
import { pathToFileURL, fileURLToPath } from "node:url";
import {
  DiagnosticSeverity,
  type Diagnostic,
  type Hover,
  type Location,
  type LocationLink,
} from "vscode-languageserver-protocol";
import { LspClient } from "./lsp-client.js";
import { findJacBinary } from "./jac-cli.js";
import type { JackalProjectConfig } from "../config/project-config.js";
import type { LspDiagnostic, LspHoverInfo, LspLocation } from "./lsp-tools.js";

const DEFAULT_AUTO_START = ["jac"];
const DEFAULT_JAC_SERVER = { command: "jac", args: ["lsp"] };
const DIAGNOSTIC_SETTLE_MS = 250;

export interface PiLspConfig {
  enabled?: boolean;
  autoStart?: string[];
  servers?: Record<string, { command: string; args?: string[]; env?: Record<string, string> }>;
}

export interface ResolvedLspConfig {
  enabled: boolean;
  autoStart: string[];
  servers: Record<string, { command: string; args: string[]; env?: Record<string, string> }>;
}

let activeService: JacLspService | null = null;

export function setActiveLspService(service: JacLspService | null): void {
  activeService = service;
}

export function getActiveLspService(): JacLspService | null {
  return activeService;
}

function findPiLspConfigPath(cwd: string): string | null {
  let cur = resolve(cwd);
  while (true) {
    const candidate = join(cur, ".pi-lsp.json");
    if (existsSync(candidate)) return candidate;
    const parent = dirname(cur);
    if (parent === cur) return null;
    cur = parent;
  }
}

export function loadPiLspConfig(cwd: string): PiLspConfig | null {
  const path = findPiLspConfigPath(cwd);
  if (!path) return null;
  try {
    const parsed = JSON.parse(readFileSync(path, "utf-8"));
    return parsed && typeof parsed === "object" ? (parsed as PiLspConfig) : null;
  } catch {
    return null;
  }
}

export function resolveLspConfig(cwd: string, projectConfig: JackalProjectConfig = {}): ResolvedLspConfig {
  const piLsp = loadPiLspConfig(cwd);
  const enabled = projectConfig.lsp !== false && piLsp?.enabled !== false;
  const autoStart = piLsp?.autoStart !== undefined ? piLsp.autoStart : DEFAULT_AUTO_START;

  const servers: ResolvedLspConfig["servers"] = {
    jac: {
      command: findJacBinary() ?? DEFAULT_JAC_SERVER.command,
      args: [...DEFAULT_JAC_SERVER.args],
    },
  };

  if (piLsp?.servers) {
    for (const [lang, conf] of Object.entries(piLsp.servers)) {
      servers[lang] = {
        command: conf.command === "jac" ? (findJacBinary() ?? "jac") : conf.command,
        args: conf.args ?? [],
        env: conf.env,
      };
    }
  }

  return { enabled, autoStart, servers };
}

function severityToString(severity: number | undefined): LspDiagnostic["severity"] {
  switch (severity) {
    case DiagnosticSeverity.Error:
      return "error";
    case DiagnosticSeverity.Warning:
      return "warning";
    case DiagnosticSeverity.Information:
      return "info";
    case DiagnosticSeverity.Hint:
      return "hint";
    default:
      return "info";
  }
}

function toLspDiagnostic(diag: Diagnostic, filePath: string): LspDiagnostic {
  return {
    file: filePath,
    line: diag.range.start.line + 1,
    column: diag.range.start.character + 1,
    severity: severityToString(diag.severity),
    message: diag.message,
    code: diag.code,
    source: diag.source,
  };
}

function formatHoverContent(hover: Hover): string[] {
  const contents = hover.contents;
  if (typeof contents === "string") return [contents];
  if (Array.isArray(contents)) {
    return contents.map((part) => (typeof part === "string" ? part : part.value));
  }
  return [contents.value];
}

function formatLocation(loc: Location, rootDir: string): LspLocation {
  const file = relative(rootDir, fileURLToPath(loc.uri));
  return {
    file,
    line: loc.range.start.line + 1,
    character: loc.range.start.character + 1,
    endLine: loc.range.end.line + 1,
    endCharacter: loc.range.end.character + 1,
  };
}

function formatLocationLink(link: LocationLink, rootDir: string): LspLocation {
  const file = relative(rootDir, fileURLToPath(link.targetUri));
  return {
    file,
    line: link.targetRange.start.line + 1,
    character: link.targetRange.start.character + 1,
    endLine: link.targetRange.end.line + 1,
    endCharacter: link.targetRange.end.character + 1,
  };
}

export class JacLspService {
  private readonly _cwd: string;
  private readonly _config: ResolvedLspConfig;
  private _clients = new Map<string, LspClient>();
  private _starting = new Map<string, Promise<LspClient>>();
  private _openVersions = new Map<string, number>();
  private _started = false;
  private _disposed = false;

  constructor(cwd: string, projectConfig: JackalProjectConfig = {}) {
    this._cwd = resolve(cwd);
    this._config = resolveLspConfig(this._cwd, projectConfig);
  }

  get config(): ResolvedLspConfig {
    return this._config;
  }

  isEnabled(): boolean {
    return this._config.enabled && this._config.autoStart.length > 0;
  }

  isReady(): boolean {
    if (!this._started || this._disposed) return false;
    return [...this._clients.values()].some((client) => client.initialized && !client.disposed);
  }

  resolvePath(filePath: string): string {
    return isAbsolute(filePath) ? resolve(filePath) : resolve(this._cwd, filePath);
  }

  getFileUri(filePath: string): string {
    return pathToFileURL(this.resolvePath(filePath)).toString();
  }

  async start(): Promise<void> {
    if (this._disposed || this._started || !this.isEnabled()) return;
    this._started = true;

    for (const languageId of this._config.autoStart) {
      void this.ensureClient(languageId).catch(() => undefined);
    }
  }

  async shutdown(): Promise<void> {
    if (this._disposed) return;
    this._disposed = true;
    const clients = [...this._clients.values()];
    this._clients.clear();
    this._starting.clear();
    await Promise.all(clients.map((client) => client.shutdown().catch(() => undefined)));
  }

  private getServerConfig(languageId: string): { command: string; args: string[]; env?: Record<string, string> } | null {
    return this._config.servers[languageId] ?? null;
  }

  private async ensureClient(languageId: string): Promise<LspClient | null> {
    if (this._disposed) return null;

    const existing = this._clients.get(languageId);
    if (existing?.initialized && !existing.disposed) return existing;

    const pending = this._starting.get(languageId);
    if (pending) return pending;

    const server = this.getServerConfig(languageId);
    if (!server) return null;

    const startPromise = (async () => {
      const client = new LspClient({
        command: server.command,
        args: server.args,
        env: server.env,
        rootDir: this._cwd,
        languageId,
      });
      await client.start();
      this._clients.set(languageId, client);
      return client;
    })();

    this._starting.set(languageId, startPromise);
    try {
      return await startPromise;
    } finally {
      this._starting.delete(languageId);
    }
  }

  private languageForPath(filePath: string): string | null {
    const ext = filePath.slice(filePath.lastIndexOf(".")).toLowerCase();
    if (ext === ".jac" || ext === ".cl.jac" || ext === ".jir") return "jac";
    return null;
  }

  private async getClientForFile(filePath: string): Promise<LspClient | null> {
    const languageId = this.languageForPath(filePath);
    if (!languageId) return null;
    return this.ensureClient(languageId);
  }

  private async syncDocument(client: LspClient, filePath: string): Promise<string> {
    const abs = this.resolvePath(filePath);
    const uri = pathToFileURL(abs).toString();
    const text = await readFile(abs, "utf-8");
    const nextVersion = (this._openVersions.get(uri) ?? 0) + 1;
    this._openVersions.set(uri, nextVersion);

    if (nextVersion === 1) {
      client.didOpen(uri, client.languageId, nextVersion, text);
    } else {
      client.didChange(uri, nextVersion, text);
    }

    return uri;
  }

  async getFileDiagnostics(filePath: string): Promise<LspDiagnostic[] | null> {
    const client = await this.getClientForFile(filePath);
    if (!client) return null;

    const abs = this.resolvePath(filePath);
    if (!existsSync(abs)) {
      return [{ file: filePath, line: 0, severity: "error", message: `File not found: ${filePath}` }];
    }

    const uri = await this.syncDocument(client, filePath);
    await new Promise((r) => setTimeout(r, DIAGNOSTIC_SETTLE_MS));
    const rel = relative(this._cwd, abs);
    return client.getDiagnostics(uri).map((diag) => toLspDiagnostic(diag, rel));
  }

  async getMultiFileDiagnostics(filePaths: string[]): Promise<Map<string, LspDiagnostic[]> | null> {
    const client = await this.ensureClient("jac");
    if (!client) return null;

    const results = new Map<string, LspDiagnostic[]>();
    for (const filePath of [...new Set(filePaths)]) {
      const diags = await this.getFileDiagnostics(filePath);
      results.set(filePath, diags ?? []);
    }
    return results;
  }

  async getHoverInfo(filePath: string, line: number, character: number): Promise<LspHoverInfo | null> {
    const client = await this.getClientForFile(filePath);
    if (!client) return null;

    const abs = this.resolvePath(filePath);
    if (!existsSync(abs)) {
      return { file: filePath, line, character, contents: [`File not found: ${filePath}`] };
    }

    const uri = await this.syncDocument(client, filePath);
    const hover = await client.sendRequest<Hover | null>("textDocument/hover", {
      textDocument: { uri },
      position: { line: line - 1, character: character - 1 },
    });

    if (!hover) {
      return { file: filePath, line, character, contents: ["No hover information available at this position."] };
    }

    return { file: filePath, line, character, contents: formatHoverContent(hover) };
  }

  async findDefinitions(filePath: string, line: number, character: number): Promise<LspLocation[] | null> {
    const client = await this.getClientForFile(filePath);
    if (!client) return null;

    const abs = this.resolvePath(filePath);
    if (!existsSync(abs)) return [];

    const uri = await this.syncDocument(client, filePath);
    const result = await client.sendRequest<Location | Location[] | LocationLink[] | null>(
      "textDocument/definition",
      {
        textDocument: { uri },
        position: { line: line - 1, character: character - 1 },
      },
    );

    if (!result) return [];

    const rootDir = this._cwd;
    if (Array.isArray(result)) {
      if (result.length === 0) return [];
      if ("targetUri" in result[0]!) {
        return (result as LocationLink[]).map((link) => formatLocationLink(link, rootDir));
      }
      return (result as Location[]).map((loc) => formatLocation(loc, rootDir));
    }

    return [formatLocation(result as Location, rootDir)];
  }

  async findReferences(filePath: string, line: number, character: number): Promise<LspLocation[] | null> {
    const client = await this.getClientForFile(filePath);
    if (!client) return null;

    const abs = this.resolvePath(filePath);
    if (!existsSync(abs)) return [];

    const uri = await this.syncDocument(client, filePath);
    const result = await client.sendRequest<Location[] | null>("textDocument/references", {
      textDocument: { uri },
      position: { line: line - 1, character: character - 1 },
      context: { includeDeclaration: true },
    });

    if (!result?.length) return [];
    return result.map((loc) => formatLocation(loc, this._cwd));
  }
}
