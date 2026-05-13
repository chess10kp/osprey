/**
 * pi-lsp-bemol — Bemol workspace provider for pi-lsp-extension.
 *
 * Detects Amazon Brazil workspaces, runs bemol to generate LSP configs,
 * and registers a WorkspaceProvider with the LSP extension via pi.events.
 *
 * Install: place in ~/.pi/agent/extensions/pi-lsp-bemol/ or load with pi -e
 *
 * Requires: bemol on PATH (toolbox install bemol)
 */

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { join } from "node:path";
import { BemolManager } from "./bemol.js";

/**
 * WorkspaceProvider interface — must match the one in pi-lsp-extension.
 * The LSP extension accepts any object with this shape via pi.events.
 */
interface WorkspaceProvider {
  readonly type: string;
  readonly workspaceRoot: string | null;
  readonly stateDir: string | null;
  getWorkspaceFolders(): { uri: string; name: string }[];
  ensureReady(sessionId?: string): Promise<boolean>;
  getStatusText(): string;
  shutdown(): void;
}

class BemolWorkspaceProvider implements WorkspaceProvider {
  readonly type = "bemol";
  readonly manager: BemolManager;

  constructor(manager: BemolManager) {
    this.manager = manager;
  }

  get workspaceRoot(): string | null {
    return this.manager.workspaceRoot;
  }

  get stateDir(): string | null {
    const root = this.manager.workspaceRoot;
    return root ? join(root, ".bemol") : null;
  }

  getWorkspaceFolders(): { uri: string; name: string }[] {
    return this.manager.getWorkspaceFolders();
  }

  async ensureReady(sessionId?: string): Promise<boolean> {
    return this.manager.ensureBemolConfig(sessionId);
  }

  getStatusText(): string {
    const hasConfig = this.manager.hasConfig();
    const hasBemol = this.manager.bemolAvailable;
    if (hasConfig) return "Brazil workspace (bemol config found)";
    if (hasBemol) return "Brazil workspace (bemol will run on first LSP use)";
    return "Brazil workspace (bemol not installed)";
  }

  shutdown(): void {
    this.manager.shutdown();
  }
}

export default function bemolExtension(pi: ExtensionAPI) {
  // Detect and register at factory time (synchronous, before any session_start).
  // This ensures the provider is available before autoStart kicks in.
  const bemol = new BemolManager(process.cwd());
  let provider: BemolWorkspaceProvider | null = null;

  if (bemol.isBrazilWorkspace) {
    provider = new BemolWorkspaceProvider(bemol);
    // Store on event bus so the LSP extension can find it regardless of load order
    (pi.events as any)["lsp:workspace-provider"] = provider;
    pi.events.emit("lsp:register-workspace-provider", provider);
  }

  // Register /bemol command and update status once we have UI context
  pi.on("session_start", async (_event, ctx) => {
    if (!provider) return;

    // Re-detect with ctx.cwd in case it differs from process.cwd()
    if (ctx.cwd !== process.cwd()) {
      const freshBemol = new BemolManager(ctx.cwd);
      if (freshBemol.isBrazilWorkspace) {
        provider = new BemolWorkspaceProvider(freshBemol);
        pi.events.emit("lsp:register-workspace-provider", provider);
      } else {
        provider = null;
        return;
      }
    }

    pi.registerCommand("bemol", {
      description: "Manage bemol: /bemol [run|watch|stop|status]",
      handler: async (args, cmdCtx) => {
        if (!provider) return;
        const mgr = provider.manager;
        const subcommand = args?.trim().toLowerCase() || "run";

        switch (subcommand) {
          case "run": {
            if (!mgr.bemolAvailable) {
              cmdCtx.ui.notify("bemol is not installed. Run: toolbox install bemol", "warning");
              return;
            }
            cmdCtx.ui.setStatus("lsp", cmdCtx.ui.theme.fg("warning", "LSP: running bemol..."));
            cmdCtx.ui.notify("Running bemol --verbose...", "info");
            const result = await mgr.runBemol();
            if (result.success) {
              const roots = mgr.getWorkspaceRoots();
              cmdCtx.ui.notify(
                `bemol completed in ${(result.duration / 1000).toFixed(1)}s\n${roots.length} package root(s) configured`,
                "info"
              );
            } else {
              cmdCtx.ui.notify(`bemol failed:\n${result.output.slice(0, 500)}`, "error");
            }
            cmdCtx.ui.setStatus("lsp", cmdCtx.ui.theme.fg("accent", "LSP: Brazil workspace (bemol done)"));
            break;
          }

          case "watch": {
            if (!mgr.bemolAvailable) {
              cmdCtx.ui.notify("bemol is not installed. Run: toolbox install bemol", "warning");
              return;
            }
            if (mgr.isWatching) {
              cmdCtx.ui.notify("bemol --watch is already running", "info");
              return;
            }
            const started = mgr.startWatch();
            if (started) {
              cmdCtx.ui.notify("Started bemol --watch in background", "info");
              cmdCtx.ui.setStatus("bemol", cmdCtx.ui.theme.fg("accent", "bemol: watching"));
            } else {
              cmdCtx.ui.notify("Failed to start bemol --watch", "error");
            }
            break;
          }

          case "stop": {
            if (!mgr.isWatching) {
              cmdCtx.ui.notify("bemol --watch is not running", "info");
              return;
            }
            mgr.stopWatch();
            cmdCtx.ui.notify("Stopped bemol --watch", "info");
            cmdCtx.ui.setStatus("bemol", "");
            break;
          }

          case "status": {
            const status = mgr.getStatus();
            const lines = [
              `Brazil workspace: ${status.isBrazilWorkspace ? "yes" : "no"}`,
              `Workspace root: ${status.workspaceRoot ?? "N/A"}`,
              `bemol available: ${status.bemolAvailable ? "yes" : "no"}`,
              `bemol config: ${status.hasConfig ? "yes" : "missing"}`,
              `bemol watch: ${status.watching ? "running" : "stopped"}`,
              `Package roots: ${status.workspaceRoots.length}`,
            ];
            if (status.workspaceRoots.length > 0) {
              const shown = status.workspaceRoots.slice(0, 10);
              for (const root of shown) {
                lines.push(`  ${root}`);
              }
              if (status.workspaceRoots.length > 10) {
                lines.push(`  ... and ${status.workspaceRoots.length - 10} more`);
              }
            }
            cmdCtx.ui.notify(lines.join("\n"), "info");
            break;
          }

          default:
            cmdCtx.ui.notify(
              "Usage: /bemol [run|watch|stop|status]\n  run    — run bemol --verbose\n  watch  — start bemol --watch\n  stop   — stop bemol --watch\n  status — show bemol status",
              "info"
            );
        }
      },
    });
  });

  pi.on("session_shutdown", async () => {
    if (provider) {
      provider.shutdown();
      provider = null;
    }
  });
}
