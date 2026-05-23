// Jackal agent session — pi-agent-core loop.

import { Agent, type AgentMessage } from "@earendil-works/pi-agent-core";
import type { Model, Api } from "@earendil-works/pi-ai";
import { JackalAuth, JackalModels } from "./auth.js";
import { JackalSessionManager } from "./session.js";
import { createCoreTools } from "./tools.js";
import { loadJackalSystemPrompt } from "./system-prompt.js";
import { JackalMcpClient } from "./mcp-client.js";
import { computeContextUsage, type ContextUsage } from "./context-usage.js";
import {
  shouldAutoCompact,
  buildMechanicalSummary,
  resolveAutoCompactConfig,
  type AutoCompactConfig,
} from "./auto-compact.js";
import type { SessionRecord } from "./session-index.js";
import {
  formatDiagnostics,
  fingerprintErrors,
  runJacCheck,
  runJacFormat,
} from "./jac-cli.js";
import { loadProjectConfig } from "./project-config.js";
import {
  type DevMode,
  cycleMode,
  isToolAllowedInPlanMode,
  shouldAutoApprove,
} from "./dev-mode.js";
import { ToolApprovalQueue } from "./tool-approval.js";
import { createAgentTool } from "./agent-tool.js";
import {
  customCommandSlashNames,
  loadCustomCommands,
  tryExpandSlashCommand,
  type CustomCommand,
} from "./custom-commands.js";
import { listSubagents } from "./subagents.js";
import { listChains } from "./chains.js";

export type SessionEventSink = (event: { type: string; [key: string]: unknown }) => void;

export interface JackalAgentSessionOptions {
  cwd: string;
  auth: JackalAuth;
  models: JackalModels;
  sessionManager: JackalSessionManager;
  systemPrompt?: string;
  initialMode?: DevMode;
  contextMaxOverride?: number | null;
  onPendingApprovalChange?: (pending: import("./tool-approval.js").PendingApproval | null) => void;
}

export interface CompactContextOptions {
  preview?: boolean;
  restore?: boolean;
  keepTail?: number;
}

export interface CompactContextResult {
  compacted: boolean;
  dropped: number;
  preview?: boolean;
  restored?: boolean;
  summaryPreview?: string;
  messageCountBefore?: number;
  messageCountAfter?: number;
}

export class JackalAgentSession {
  private _agent!: Agent;
  private _auth: JackalAuth;
  private _models: JackalModels;
  private _sessionManager: JackalSessionManager;
  private _listeners = new Set<SessionEventSink>();
  private _unsubAgent: () => void;
  private _disposed = false;
  private _mcp: JackalMcpClient | null = null;
  private _mcpLazyTimer: ReturnType<typeof setTimeout> | null = null;
  private _mcpConnecting = false;
  private _mode: DevMode;
  private _approvalQueue: ToolApprovalQueue;
  private _systemPrompt: string;
  private _contextMaxOverride: number | null;
  private _autoCompactConfig: AutoCompactConfig;
  private _customCommands: CustomCommand[] = [];

  constructor(options: JackalAgentSessionOptions) {
    this._auth = options.auth;
    this._models = options.models;
    this._sessionManager = options.sessionManager;
    this._mode = options.initialMode ?? "normal";
    this._approvalQueue = new ToolApprovalQueue(options.onPendingApprovalChange);
    this._systemPrompt = loadJackalSystemPrompt(options.cwd, options.systemPrompt);
    this._contextMaxOverride =
      typeof options.contextMaxOverride === "number" && options.contextMaxOverride > 0
        ? options.contextMaxOverride
        : null;
    this._autoCompactConfig = resolveAutoCompactConfig(loadProjectConfig(options.cwd));

    const saved = options.sessionManager.model;
    const savedRef = options.sessionManager.savedModelRef;
    const resolvedSaved =
      saved ??
      (savedRef ? this._models.find(savedRef.provider, savedRef.id) : undefined);

    const initialModel =
      resolvedSaved ??
      this._models.getAvailable()[0] ??
      this._models.getAll()[0];

    if (!initialModel) {
      throw new Error("No models available. Configure auth with /login or env API keys.");
    }

    const coreTools = createCoreTools(options.cwd);
    const agentTool = createAgentTool({
      cwd: options.cwd,
      auth: this._auth,
      models: this._models,
      getParentModel: () => this._agent?.state.model ?? initialModel,
      getParentTools: () => this._agent?.state.tools ?? coreTools,
      getMode: () => this._mode,
    });

    this._agent = new Agent({
      initialState: {
        systemPrompt: this._systemPrompt,
        model: initialModel,
        tools: [...coreTools, agentTool],
        messages: options.sessionManager.messages,
      },
      getApiKey: (provider) => this._auth.getApiKey(provider),
      beforeToolCall: async ({ toolCall, args }) => {
        const toolName = toolCall.name;
        const params =
          args && typeof args === "object" && !Array.isArray(args)
            ? (args as Record<string, unknown>)
            : {};

        if (this._mode === "plan" && !isToolAllowedInPlanMode(toolName)) {
          return {
            block: true,
            reason: `Tool "${toolName}" is not available in plan mode.`,
          };
        }

        if (shouldAutoApprove(this._mode, toolName, params)) {
          return undefined;
        }

        const approved = await this._approvalQueue.requestApproval(
          toolCall.id,
          toolName,
          params,
        );

        if (!approved) {
          return {
            block: true,
            reason: `Tool "${toolName}" was rejected.`,
          };
        }

        return undefined;
      },
    });

    if (resolvedSaved) {
      this._sessionManager.setModel(resolvedSaved);
    }

    this._unsubAgent = this._agent.subscribe((event) => {
      this._forwardEvent(event);
      if (event.type === "agent_end") {
        this._sessionManager.setMessages(this._agent.state.messages);
      }
    });

    this._emit({
      type: "session_start",
      sessionId: this._sessionManager.sessionId,
      sessionName: this._sessionManager.sessionName,
    });

    if (initialModel) {
      this._emit({
        type: "model_select",
        provider: initialModel.provider,
        model: initialModel.id,
      });
    }

    this._emit({ type: "mode_change", mode: this._mode });
  }

  get customCommands(): CustomCommand[] {
    return this._customCommands;
  }

  getCustomCommandSlashNames(): string[] {
    return customCommandSlashNames(this._sessionManager.cwd);
  }

  resolveSlashCommand(text: string): string | null {
    return tryExpandSlashCommand(text, this._sessionManager.cwd);
  }

  reloadCustomCommands(): void {
    this._reloadCustomCommands(this._sessionManager.cwd);
  }

  private _reloadCustomCommands(cwd: string): void {
    this._customCommands = loadCustomCommands(cwd);
    this._emit({
      type: "custom_commands_loaded",
      count: this._customCommands.length,
      commands: this._customCommands.map((cmd) => cmd.name),
    });
  }

  get mode(): DevMode {
    return this._mode;
  }

  setMode(mode: DevMode): void {
    this._mode = mode;
    this._emit({ type: "mode_change", mode });
  }

  cycleMode(): DevMode {
    const next = cycleMode(this._mode);
    this.setMode(next);
    return next;
  }

  approveTool(): boolean {
    return this._approvalQueue.approve();
  }

  rejectTool(): boolean {
    return this._approvalQueue.reject();
  }

  get messages(): AgentMessage[] {
    return this._agent.state.messages;
  }

  get currentModel(): Model<Api> {
    return this._agent.state.model;
  }

  /** Check if auto-compact should trigger and run it if needed. */
  private _maybeAutoCompact(): void {
    const usage = this.getContextUsage();
    if (!shouldAutoCompact(usage, this._autoCompactConfig)) return;

    const result = this.compactContext({
      keepTail: this._autoCompactConfig.keepTail,
    });

    if (result.compacted && this._autoCompactConfig.notify) {
      this._emit({
        type: "auto_compact",
        dropped: result.dropped,
        messageCountBefore: result.messageCountBefore,
        messageCountAfter: result.messageCountAfter,
        percentBefore: usage.percent,
      });
    }
  }

  /** Restore conversation from a checkpoint (files restored separately). */
  restoreCheckpointConversation(
    messages: AgentMessage[],
    modelRef?: { provider: string; id: string },
  ): void {
    const resolved = modelRef ? this._models.find(modelRef.provider, modelRef.id) : undefined;

    if (resolved) {
      this._agent.state.model = resolved;
      this._sessionManager.setModel(resolved);
      this._emit({
        type: "model_select",
        provider: resolved.provider,
        model: resolved.id,
      });
    }

    this._agent.state.messages = messages;
    this._sessionManager.setMessages(messages);
    this._emit({
      type: "session_start",
      reason: "checkpoint_load",
      sessionId: this._sessionManager.sessionId,
      sessionName: this._sessionManager.sessionName,
      messages,
    });
  }

  subscribe(handler: SessionEventSink): () => void {
    this._listeners.add(handler);
    return () => {
      this._listeners.delete(handler);
    };
  }

  /** Boot session without blocking on MCP — call scheduleMcpConnect() after UI is ready. */
  async initialize(): Promise<void> {
    this._reloadCustomCommands(this._sessionManager.cwd);
    this._emit({
      type: "subagents_loaded",
      agents: listSubagents(this._sessionManager.cwd).map((a) => a.name),
      chains: listChains(this._sessionManager.cwd).map((c) => c.name),
    });
  }

  /** Defer MCP spawn until after first frame (default 100ms). */
  scheduleMcpConnect(delayMs = 100): void {
    if (this._disposed || this._mcpConnecting || this._mcp) return;
    if (this._mcpLazyTimer) return;

    this._mcpLazyTimer = setTimeout(() => {
      this._mcpLazyTimer = null;
      void this.connectMcpLazy();
    }, delayMs);
  }

  /** Connect to Jac MCP in the background; emits mcp_connecting → mcp_ready. */
  async connectMcpLazy(): Promise<void> {
    if (this._disposed || this._mcpConnecting || this._mcp) return;
    this._mcpConnecting = true;
    this._mcp = new JackalMcpClient();
    this._emit({ type: "mcp_connecting", server: "jac" });

    const initOnce = async () => {
      await this._mcp!.connectFromConfig(this._sessionManager.cwd);
      const defs = await this._mcp!.listToolDefs();
      const mcpTools = this._mcp!.toAgentTools(defs);
      const existing = new Set(this._agent.state.tools.map((t) => t.name));
      this._agent.state.tools = [
        ...this._agent.state.tools,
        ...mcpTools.filter((t) => !existing.has(t.name)),
      ];
      this._emit({
        type: "mcp_ready",
        server: "jac",
        toolCount: defs.length,
      });
    };

    try {
      await initOnce();
    } catch (error) {
      try {
        await new Promise((r) => setTimeout(r, 250));
        await initOnce();
      } catch (finalError) {
        const errText = String(finalError ?? error);
        const missingJacMcp = errText.includes("Jac MCP is unavailable in this Jac CLI build");
        this._emit({
          type: "mcp_status",
          connected: false,
          server: "jac",
          toolCount: 0,
          error: missingJacMcp ? null : errText,
        });
        if (this._mcp) {
          this._mcp.disconnect().catch(() => undefined);
          this._mcp = null;
        }
      }
    } finally {
      this._mcpConnecting = false;
    }
  }

  /** True while a prompt turn is in flight (including awaited agent_end listeners). */
  isProcessing(): boolean {
    return this._agent.signal !== undefined;
  }

  async sendUserMessage(
    text: string,
    _opts?: { deliverAs?: string },
  ): Promise<"sent" | "queued"> {
    const expanded = tryExpandSlashCommand(text, this._sessionManager.cwd);
    const outgoing = expanded ?? text;

    if (this.isProcessing()) {
      this._agent.followUp({
        role: "user",
        content: outgoing,
        timestamp: Date.now(),
      } as AgentMessage);
      return "queued";
    }

    await this._agent.prompt(outgoing);

    // Auto-compact check after each successful turn
    this._maybeAutoCompact();

    return "sent";
  }

  async abort(): Promise<void> {
    this._approvalQueue.cancel();
    this._agent.abort();
  }

  async runFixFlow(maxAttempts?: number, targetFile?: string): Promise<string> {
    const cwd = this._sessionManager.cwd;
    const cfg = loadProjectConfig(cwd);
    const cap = maxAttempts ?? cfg.maxFixAttempts ?? 3;
    const files = targetFile ? [targetFile] : undefined;
    const lines: string[] = [];
    let lastFingerprint: string | undefined;

    for (let attempt = 1; attempt <= cap; attempt++) {
      let check;
      try {
        check = await runJacCheck(cwd, files);
      } catch (error) {
        return `jac check failed: ${String(error)}`;
      }

      if (check.exitError) {
        return `jac check failed:\n${check.exitError}`;
      }

      const errors = check.diagnostics.filter((d) => d.severity === "error");
      const warnings = check.diagnostics.filter((d) => d.severity === "warning");

      if (errors.length === 0) {
        lines.push(
          attempt === 1
            ? "jac check passed — nothing to fix."
            : `jac check passed after ${attempt - 1} fix attempt(s).`,
        );
        if (warnings.length > 0) {
          lines.push(`${warnings.length} warning(s) remain:\n${formatDiagnostics(warnings)}`);
        }
        return lines.join("\n");
      }

      const fp = fingerprintErrors(errors);
      if (lastFingerprint && lastFingerprint === fp) {
        lines.push(`attempt ${attempt}: no progress — same errors as previous attempt`);
        lines.push(formatDiagnostics(errors));
        break;
      }
      lastFingerprint = fp;

      lines.push(`attempt ${attempt}: ${errors.length} error(s)`);
      lines.push(formatDiagnostics(errors));

      const formatTargets = [...new Set(errors.map((d) => d.file).filter(Boolean))];
      if (formatTargets.length > 0) {
        try {
          const formatted = await runJacFormat(cwd, formatTargets);
          lines.push(
            formatted.changed
              ? `formatted: ${formatTargets.join(", ")}`
              : "format: no changes",
          );
        } catch (error) {
          lines.push(`format failed: ${String(error)}`);
        }
      }

      const postFormat = await runJacCheck(cwd, files);
      const postErrors = postFormat.diagnostics.filter((d) => d.severity === "error");
      if (postErrors.length === 0) {
        lines.push(`attempt ${attempt}: resolved after format`);
        return lines.join("\n");
      }

      const hasValidate = this._agent.state.tools.some((t) => t.name === "validate_jac");
      if (hasValidate && attempt < cap) {
        const scope = targetFile ? ` for \`${targetFile}\`` : "";
        const prompt = [
          `\`jac check\`${scope} reported ${postErrors.length} error(s) (fix attempt ${attempt}/${cap}):`,
          "",
          formatDiagnostics(postErrors),
          "",
          "Fix these errors using Jac MCP tools:",
          "1. Call `explain_error` for unfamiliar codes.",
          "2. Read each file at the reported line.",
          "3. Apply a focused edit.",
          "4. Call `validate_jac` to verify.",
          "5. Stop after at most 3 attempts on the same file.",
        ].join("\n");
        await this.sendUserMessage(prompt);
        lines.push(`attempt ${attempt}: sent agent fix prompt (${postErrors.length} error(s) remain)`);
        return lines.join("\n");
      }
    }

    const finalCheck = await runJacCheck(cwd, files);
    const remaining = finalCheck.diagnostics.filter((d) => d.severity === "error");
    if (remaining.length > 0) {
      lines.push(`unresolved after ${cap} attempt(s):`);
      lines.push(formatDiagnostics(remaining));
    }

    return lines.join("\n") || "fix flow failed";
  }

  appendAssistantNotice(text: string): void {
    const msg = {
      role: "assistant",
      content: [{ type: "text", text }],
      timestamp: Date.now(),
    } as unknown as AgentMessage;
    this._agent.state.messages = [...this._agent.state.messages, msg];
    this._sessionManager.setMessages(this._agent.state.messages);
    this._emit({ type: "message_start", message: msg });
    this._emit({ type: "message_update", assistantMessageEvent: { type: "text_delta", delta: text } });
    this._emit({ type: "message_end", message: msg });
  }

  async runTool(name: string, params: Record<string, unknown> = {}): Promise<string> {
    const tool = this._agent.state.tools.find((t) => t.name === name);
    if (!tool) {
      throw new Error(`Tool not available: ${name}`);
    }

    const toolCallId = `manual_${name}_${Date.now()}`;
    this._emit({ type: "tool_execution_start", toolCallId, toolName: name, input: params });

    try {
      const result = await tool.execute(toolCallId, params);
      this._emit({ type: "tool_execution_end", toolCallId, toolName: name, input: params, result: result.details });

      const text = (result.content ?? [])
        .filter((c) => c.type === "text")
        .map((c) => c.text)
        .join("\n");

      const finalText = text || `${name} completed`;
      const msg = {
        role: "assistant",
        content: [{ type: "text", text: finalText }],
        timestamp: Date.now(),
      } as unknown as AgentMessage;
      this._agent.state.messages = [...this._agent.state.messages, msg];
      this._sessionManager.setMessages(this._agent.state.messages);

      this._emit({ type: "message_start", message: msg });
      this._emit({ type: "message_update", assistantMessageEvent: { type: "text_delta", delta: finalText } });
      this._emit({ type: "message_end", message: msg });
      return finalText;
    } catch (error) {
      this._emit({ type: "tool_execution_end", toolCallId, toolName: name, input: params, result: { error: String(error) } });
      throw error;
    }
  }

  async setModel(model: Model<Api>): Promise<void> {
    this._agent.state.model = model;
    this._sessionManager.setModel(model);
    this._emit({
      type: "model_select",
      provider: model.provider,
      model: model.id,
    });
  }

  getContextUsage(): ContextUsage {
    return computeContextUsage({
      messages: this._agent.state.messages,
      systemPrompt: this._systemPrompt,
      model: this._agent.state.model,
      contextMaxOverride: this._contextMaxOverride,
    });
  }

  setContextMax(n: number | null): void {
    this._contextMaxOverride = typeof n === "number" && n > 0 ? n : null;
  }

  getContextMax(): number {
    return this.getContextUsage().max;
  }

  exportSessionMarkdown(): string {
    this._sessionManager.setMessages(this._agent.state.messages);
    return this._sessionManager.exportMarkdown();
  }

  resumeFromRecord(record: SessionRecord): void {
    this._sessionManager.applyRecord(record);

    const savedRef = record.model;
    const resolved =
      savedRef ? this._models.find(savedRef.provider, savedRef.id) : undefined;

    if (resolved) {
      this._agent.state.model = resolved;
      this._sessionManager.setModel(resolved);
      this._emit({
        type: "model_select",
        provider: resolved.provider,
        model: resolved.id,
      });
    }

    this._agent.state.messages = record.messages ?? [];
    this._emit({
      type: "session_start",
      reason: "resume",
      sessionId: record.sessionId,
      sessionName: record.sessionName,
      messages: record.messages ?? [],
    });
  }

  compactContext(options: CompactContextOptions = {}): CompactContextResult {
    if (options.restore) {
      const backup = this._sessionManager.loadCompactionBackup();
      if (!backup) {
        return { compacted: false, dropped: 0, restored: false };
      }
      this._agent.state.messages = backup;
      this._sessionManager.setMessages(backup);
      this._sessionManager.clearCompactionBackup();
      this._emit({ type: "compaction_end", restored: true, messages: backup });
      return {
        compacted: false,
        dropped: 0,
        restored: true,
        messageCountAfter: backup.length,
      };
    }

    const all = this._agent.state.messages;
    const keepTail = options.keepTail ?? 12;
    if (all.length <= keepTail) {
      return {
        compacted: false,
        dropped: 0,
        messageCountBefore: all.length,
        messageCountAfter: all.length,
      };
    }

    const dropped = all.slice(0, all.length - keepTail);
    const kept = all.slice(all.length - keepTail);

    const summaryText = buildMechanicalSummary(dropped);
    const summary: AgentMessage = {
      role: "user",
      content: summaryText,
      timestamp: Date.now(),
    };

    if (options.preview) {
      return {
        compacted: false,
        dropped: dropped.length,
        preview: true,
        summaryPreview: summaryText,
        messageCountBefore: all.length,
        messageCountAfter: kept.length + 1,
      };
    }

    this._emit({ type: "compaction_start" });
    this._sessionManager.saveCompactionBackup(all);

    this._agent.state.messages = [summary, ...kept];
    this._sessionManager.setMessages(this._agent.state.messages);
    this._emit({ type: "compaction_end", messages: this._agent.state.messages });

    return {
      compacted: true,
      dropped: dropped.length,
      messageCountBefore: all.length,
      messageCountAfter: kept.length + 1,
    };
  }

  renameSession(name: string): void {
    this._sessionManager.rename(name);
    this._emit({
      type: "session_start",
      reason: "rename",
      sessionId: this._sessionManager.sessionId,
      sessionName: this._sessionManager.sessionName,
    });
  }

  /** Start a fresh session: clear agent context and persist an empty transcript. */
  resetForNewSession(): void {
    this._sessionManager.newSession();
    this._agent.state.messages = [];
    this._emit({
      type: "session_start",
      reason: "new",
      sessionId: this._sessionManager.sessionId,
      sessionName: this._sessionManager.sessionName,
    });
  }

  dispose(): void {
    if (this._disposed) return;
    this._disposed = true;
    this._approvalQueue.cancel();
    if (this._mcpLazyTimer) {
      clearTimeout(this._mcpLazyTimer);
      this._mcpLazyTimer = null;
    }
    this._sessionManager.dispose();
    this._agent.abort();
    this._unsubAgent();
    if (this._mcp) {
      this._mcp.disconnect().catch(() => undefined);
      this._mcp = null;
    }
    this._emit({ type: "session_shutdown" });
    this._listeners.clear();
  }

  private _emit(event: { type: string; [key: string]: unknown }): void {
    for (const fn of this._listeners) {
      try {
        fn(event);
      } catch {
        /* swallow */
      }
    }
  }

  private _forwardEvent(event: { type: string; [key: string]: unknown }): void {
    if (event.type === "message_update") {
      const ame = event.assistantMessageEvent as { type?: string; delta?: string } | undefined;
      if (ame?.type === "text_delta" && ame.delta) {
        this._emit({
          type: "message_update",
          assistantMessageEvent: { type: "text_delta", delta: ame.delta },
        });
        return;
      }
    }
    this._emit(event);
  }
}
