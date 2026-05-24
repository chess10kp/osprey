/**
 * LSP Client — JSON-RPC client for LSP servers.
 *
 * Adapted from pi-lsp-extension (MIT).
 */

import { spawn, type ChildProcess } from "node:child_process";
import { connect as netConnect, type Socket } from "node:net";
import { pathToFileURL } from "node:url";
import {
  createMessageConnection,
  StreamMessageReader,
  StreamMessageWriter,
  SocketMessageReader,
  SocketMessageWriter,
  type MessageConnection,
} from "vscode-languageserver-protocol/node.js";
import type {
  InitializeParams,
  InitializeResult,
  ServerCapabilities,
  Diagnostic,
  PublishDiagnosticsParams,
} from "vscode-languageserver-protocol";

export interface LspClientOptions {
  command: string;
  args: string[];
  rootDir: string;
  languageId: string;
  env?: Record<string, string>;
  workspaceFolders?: { uri: string; name: string }[];
  socketPath?: string;
  initializationOptions?: Record<string, unknown>;
  onUnexpectedExit?: (code: number | null) => void;
}

export class LspClient {
  private process: ChildProcess | null = null;
  private socket: Socket | null = null;
  private connection: MessageConnection | null = null;
  private _serverCapabilities: ServerCapabilities | null = null;
  private _diagnostics: Map<string, Diagnostic[]> = new Map();
  private _initialized = false;
  private _disposed = false;
  private _isDaemonClient = false;

  readonly languageId: string;
  readonly command: string;
  readonly rootDir: string;

  constructor(private options: LspClientOptions) {
    this.languageId = options.languageId;
    this.command = options.command;
    this.rootDir = options.rootDir;
  }

  get initialized(): boolean {
    return this._initialized;
  }

  get disposed(): boolean {
    return this._disposed;
  }

  get serverCapabilities(): ServerCapabilities | null {
    return this._serverCapabilities;
  }

  getDiagnostics(uri: string): Diagnostic[] {
    return this._diagnostics.get(uri) ?? [];
  }

  getAllDiagnostics(): Map<string, Diagnostic[]> {
    return new Map(this._diagnostics);
  }

  async start(): Promise<void> {
    if (this._initialized || this._disposed) return;

    if (this.options.socketPath) {
      await this.connectToSocket(this.options.socketPath);
    } else {
      await this.spawnDirect();
    }
  }

  private async connectToSocket(socketPath: string): Promise<void> {
    this._isDaemonClient = true;

    return new Promise((resolve, reject) => {
      let settled = false;
      const settle = (fn: () => void) => {
        if (!settled) {
          settled = true;
          fn();
        }
      };

      const socket = netConnect(socketPath, () => {
        this.socket = socket;

        const reader = new SocketMessageReader(socket);
        const writer = new SocketMessageWriter(socket);
        this.connection = createMessageConnection(reader, writer);

        this.connection.onNotification(
          "textDocument/publishDiagnostics",
          (params: PublishDiagnosticsParams) => {
            this._diagnostics.set(params.uri, params.diagnostics);
          },
        );

        this.connection.onError(([err]) => {
          console.error(`[LSP ${this.languageId}] Connection error: ${err.message}`);
        });

        this.connection.onClose(() => {
          if (!this._disposed) {
            this._initialized = false;
          }
        });

        this.connection.listen();
        this._initialized = true;
        settle(() => resolve());
      });

      socket.on("error", (err) => {
        if (!this._initialized) {
          settle(() => reject(new Error(`Failed to connect to LSP daemon: ${err.message}`)));
        } else {
          this._initialized = false;
        }
      });

      socket.on("close", () => {
        if (!this._disposed) {
          this._initialized = false;
          this.options.onUnexpectedExit?.(null);
        }
      });

      setTimeout(() => {
        if (!settled) {
          socket.destroy();
          settle(() => reject(new Error("Timeout connecting to LSP daemon socket")));
        }
      }, 10_000);
    });
  }

  private async spawnDirect(): Promise<void> {
    const env = { ...process.env, ...this.options.env };

    this.process = spawn(this.options.command, this.options.args, {
      stdio: ["pipe", "pipe", "pipe"],
      env,
      cwd: this.rootDir,
    });

    if (!this.process.stdout || !this.process.stdin) {
      throw new Error(`Failed to spawn LSP server: ${this.options.command}`);
    }

    await new Promise<void>((resolve, reject) => {
      const onSpawn = () => {
        cleanup();
        resolve();
      };
      const onError = (err: Error) => {
        cleanup();
        reject(new Error(`Failed to spawn LSP server "${this.options.command}": ${err.message}`));
      };
      const cleanup = () => {
        this.process?.removeListener("spawn", onSpawn);
        this.process?.removeListener("error", onError);
      };
      this.process!.on("spawn", onSpawn);
      this.process!.on("error", onError);
    });

    this.process.stderr?.resume();

    const stdin = this.process.stdin!;
    const originalWrite = stdin.write;
    stdin.write = function (this: typeof stdin, ...args: unknown[]): boolean {
      if (this.destroyed || this.writableEnded || this.writableFinished) {
        const cb = args[args.length - 1];
        if (typeof cb === "function") process.nextTick(cb as () => void);
        return false;
      }
      try {
        return originalWrite.apply(this, args as Parameters<typeof originalWrite>);
      } catch (err: unknown) {
        const code = (err as NodeJS.ErrnoException)?.code;
        if (code === "EPIPE" || code === "ERR_STREAM_DESTROYED") {
          const cb = args[args.length - 1];
          if (typeof cb === "function") process.nextTick(cb as () => void);
          return false;
        }
        throw err;
      }
    } as typeof stdin.write;

    stdin.on("error", (err: NodeJS.ErrnoException) => {
      if (err?.code === "EPIPE") return;
      console.error(`[LSP ${this.languageId}] stdin error: ${err.message}`);
    });

    this.process.on("error", (err) => {
      console.error(`[LSP ${this.languageId}] Process error: ${err.message}`);
      this._initialized = false;
      this.disposeConnection();
    });

    this.process.on("exit", (code) => {
      if (!this._disposed) {
        console.error(`[LSP ${this.languageId}] Server exited with code ${code}`);
        this._initialized = false;
        this.disposeConnection();
        this.options.onUnexpectedExit?.(code);
      }
    });

    const reader = new StreamMessageReader(this.process.stdout);
    const writer = new StreamMessageWriter(this.process.stdin);
    this.connection = createMessageConnection(reader, writer);

    this.connection.onNotification(
      "textDocument/publishDiagnostics",
      (params: PublishDiagnosticsParams) => {
        this._diagnostics.set(params.uri, params.diagnostics);
      },
    );

    this.connection.onError(([err]) => {
      console.error(`[LSP ${this.languageId}] Connection error: ${err.message}`);
    });

    this.connection.onClose(() => {
      if (!this._disposed) {
        this._initialized = false;
      }
    });

    this.connection.listen();

    const rootUri = pathToFileURL(this.rootDir).toString();
    const defaultFolder = { uri: rootUri, name: this.rootDir.split("/").pop() ?? "workspace" };
    const workspaceFolders =
      this.options.workspaceFolders && this.options.workspaceFolders.length > 0
        ? this.options.workspaceFolders
        : [defaultFolder];

    const initParams: InitializeParams = {
      processId: process.pid,
      capabilities: {
        textDocument: {
          synchronization: {
            didSave: true,
            dynamicRegistration: false,
          },
          hover: {
            contentFormat: ["plaintext", "markdown"],
          },
          definition: {},
          references: {},
          documentSymbol: {
            hierarchicalDocumentSymbolSupport: true,
          },
          rename: {
            prepareSupport: false,
          },
          publishDiagnostics: {
            relatedInformation: true,
          },
          completion: {
            completionItem: {
              snippetSupport: false,
            },
          },
        },
        workspace: {
          workspaceFolders: true,
          symbol: {},
        },
      },
      rootUri,
      workspaceFolders,
      ...(this.options.initializationOptions
        ? { initializationOptions: this.options.initializationOptions }
        : {}),
    };

    const result: InitializeResult = await this.connection.sendRequest("initialize", initParams);
    this._serverCapabilities = result.capabilities;
    this.connection.sendNotification("initialized", {});
    this._initialized = true;
  }

  private disposeConnection(): void {
    try {
      if (this.connection) {
        this.connection.dispose();
      }
    } catch {
      /* ignore */
    }
    this.connection = null;
  }

  async sendRequest<R>(method: string, params: unknown): Promise<R> {
    if (!this.connection || !this._initialized) {
      throw new Error(`LSP ${this.languageId} not initialized`);
    }
    return this.connection.sendRequest(method, params) as Promise<R>;
  }

  sendNotification(method: string, params: unknown): void {
    if (!this.connection || !this._initialized) return;
    this.connection.sendNotification(method, params);
  }

  didOpen(uri: string, languageId: string, version: number, text: string): void {
    this.sendNotification("textDocument/didOpen", {
      textDocument: { uri, languageId, version, text },
    });
  }

  didChange(uri: string, version: number, text: string): void {
    this.sendNotification("textDocument/didChange", {
      textDocument: { uri, version },
      contentChanges: [{ text }],
    });
  }

  didClose(uri: string): void {
    this.sendNotification("textDocument/didClose", {
      textDocument: { uri },
    });
  }

  async shutdown(): Promise<void> {
    if (this._disposed) return;
    this._disposed = true;
    this._initialized = false;

    if (this._isDaemonClient) {
      this.disposeConnection();
      if (this.socket) {
        this.socket.destroy();
      }
      this.socket = null;
      return;
    }

    try {
      if (this.connection) {
        const shutdownReq = this.connection.sendRequest("shutdown").catch(() => undefined);
        await Promise.race([shutdownReq, new Promise((resolve) => setTimeout(resolve, 3000))]);
        try {
          this.connection.sendNotification("exit");
        } catch {
          /* ignore */
        }
      }
    } catch {
      /* ignore */
    }
    this.disposeConnection();

    if (this.process) {
      this.process.kill("SIGTERM");
      setTimeout(() => {
        if (this.process && !this.process.killed) {
          this.process.kill("SIGKILL");
        }
      }, 2000);
    }

    this.process = null;
  }
}
