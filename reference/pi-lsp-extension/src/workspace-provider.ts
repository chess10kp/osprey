/**
 * Workspace Provider — abstraction for workspace detection and configuration.
 *
 * Separates workspace-specific concerns (root detection, multi-root folders,
 * state directories) from the LSP manager.
 *
 * External extensions can provide custom implementations via pi.events:
 *   pi.events.emit("lsp:workspace-provider", myProvider);
 */

export interface WorkspaceProvider {
  /** Provider type identifier */
  readonly type: string;

  /** Workspace root directory (if detected — may differ from cwd) */
  readonly workspaceRoot: string | null;

  /** Directory for persistent state (daemon sockets, PIDs, locks). Null disables daemon mode. */
  readonly stateDir: string | null;

  /** Get workspace folders for multi-root LSP initialization */
  getWorkspaceFolders(): { uri: string; name: string }[];

  /** One-time setup before first LSP server start. Returns true if ready. */
  ensureReady(sessionId?: string): Promise<boolean>;

  /** Human-readable status for UI */
  getStatusText(): string;

  /** Clean up resources */
  shutdown(): void;
}

/**
 * Default provider for standard workspaces.
 * No special workspace detection, no daemon support, no multi-root.
 */
export class DefaultWorkspaceProvider implements WorkspaceProvider {
  readonly type = "default";
  readonly workspaceRoot = null;
  readonly stateDir = null;

  getWorkspaceFolders(): { uri: string; name: string }[] {
    return [];
  }

  async ensureReady(): Promise<boolean> {
    return true;
  }

  getStatusText(): string {
    return "";
  }

  shutdown(): void {}
}
