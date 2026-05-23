// Jackal agent session — pi-agent-core loop.

import { Agent, type AgentMessage } from "@earendil-works/pi-agent-core";
import type { Model, Api } from "@earendil-works/pi-ai";
import { JackalAuth, JackalModels } from "./auth.js";
import { JackalSessionManager } from "./session.js";
import { createCoreTools } from "./tools.js";
import { loadJackalSystemPrompt } from "./system-prompt.js";
import { JackalMcpClient } from "./mcp-client.js";

export type SessionEventSink = (event: { type: string; [key: string]: unknown }) => void;

export interface JackalAgentSessionOptions {
  cwd: string;
  auth: JackalAuth;
  models: JackalModels;
  sessionManager: JackalSessionManager;
  systemPrompt?: string;
}

export class JackalAgentSession {
  private _agent: Agent;
  private _auth: JackalAuth;
  private _models: JackalModels;
  private _sessionManager: JackalSessionManager;
  private _listeners = new Set<SessionEventSink>();
  private _unsubAgent: () => void;
  private _disposed = false;
  private _mcp: JackalMcpClient | null = null;

  constructor(options: JackalAgentSessionOptions) {
    this._auth = options.auth;
    this._models = options.models;
    this._sessionManager = options.sessionManager;

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

    this._agent = new Agent({
      initialState: {
        systemPrompt: loadJackalSystemPrompt(options.cwd, options.systemPrompt),
        model: initialModel,
        tools: createCoreTools(options.cwd),
        messages: options.sessionManager.messages,
      },
      getApiKey: (provider) => this._auth.getApiKey(provider),
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
  }

  get messages(): AgentMessage[] {
    return this._agent.state.messages;
  }

  subscribe(handler: SessionEventSink): () => void {
    this._listeners.add(handler);
    return () => {
      this._listeners.delete(handler);
    };
  }

  async initialize(): Promise<void> {
    this._mcp = new JackalMcpClient();

    const initOnce = async () => {
      await this._mcp!.connectFromConfig(this._sessionManager.cwd);
      const defs = await this._mcp!.listToolDefs();
      const mcpTools = this._mcp!.toAgentTools(defs);
      const existing = new Set(this._agent.state.tools.map((t) => t.name));
      this._agent.state.tools = [
        ...this._agent.state.tools,
        ...mcpTools.filter((t) => !existing.has(t.name)),
      ];
      this._emit({ type: "mcp_status", connected: true, server: "jac", toolCount: defs.length, error: null });
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
        // keep running without MCP tools
      }
    }
  }

  async sendUserMessage(
    text: string,
    _opts?: { deliverAs?: string },
  ): Promise<void> {
    await this._agent.prompt(text);
  }

  async abort(): Promise<void> {
    this._agent.abort();
  }

  async runFixFlow(maxAttempts = 3): Promise<string> {
    const hasValidate = this._agent.state.tools.some((t) => t.name === "validate_jac");
    if (!hasValidate) {
      return this.runTool("jac_fix", { maxAttempts });
    }

    const lines: string[] = [];
    for (let i = 1; i <= maxAttempts; i++) {
      try {
        const validate = await this.runTool("validate_jac", {});
        lines.push(`attempt ${i}: validate_jac ok`);
        lines.push(validate.slice(0, 400));
        try {
          const runOut = await this.runTool("run_jac", {});
          lines.push(`attempt ${i}: run_jac ok`);
          lines.push(runOut.slice(0, 400));
        } catch {
          lines.push(`attempt ${i}: run_jac unavailable/failed`);
        }
        return lines.join("\n");
      } catch (error) {
        lines.push(`attempt ${i}: validate_jac failed: ${String(error)}`);
        await this.runTool("jac_cli", { args: ["format", "."] }).catch(() => undefined);
      }
    }

    return lines.join("\n") || "fix flow failed";
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

  compactContext(): { compacted: boolean; dropped: number } {
    const all = this._agent.state.messages;
    const keepTail = 12;
    if (all.length <= keepTail) {
      return { compacted: false, dropped: 0 };
    }

    this._emit({ type: "compaction_start" });

    const dropped = all.slice(0, all.length - keepTail);
    const kept = all.slice(all.length - keepTail);

    const lines = dropped
      .map((m) => {
        const c = typeof (m as { content?: unknown }).content === "string"
          ? String((m as { content?: unknown }).content)
          : JSON.stringify((m as { content?: unknown }).content ?? "");
        return `${m.role}: ${c.slice(0, 200)}`;
      })
      .slice(-30);

    const summary: AgentMessage = {
      role: "user",
      content: `Context summary (older messages compacted):\n${lines.join("\n")}`,
      timestamp: Date.now(),
    };

    this._agent.state.messages = [summary, ...kept];
    this._sessionManager.setMessages(this._agent.state.messages);
    this._emit({ type: "compaction_end" });

    return { compacted: true, dropped: dropped.length };
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
