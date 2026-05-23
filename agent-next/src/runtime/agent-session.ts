// Jackal agent session — pi-agent-core loop.

import { Agent, type AgentMessage } from "@earendil-works/pi-agent-core";
import type { Model, Api } from "@earendil-works/pi-ai";
import { JackalAuth, JackalModels } from "./auth.js";
import { JackalSessionManager } from "./session.js";

const DEFAULT_SYSTEM = `You are Jackal, a Jac/Jaseci coding assistant.
Be concise, evidence-based, and correct. When unsure about Jac syntax, say so.`;

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

  constructor(options: JackalAgentSessionOptions) {
    this._auth = options.auth;
    this._models = options.models;
    this._sessionManager = options.sessionManager;

    const saved = options.sessionManager.model;
    const initialModel =
      saved ??
      this._models.getAvailable()[0] ??
      this._models.getAll()[0];

    if (!initialModel) {
      throw new Error("No models available. Configure auth with /login or env API keys.");
    }

    this._agent = new Agent({
      initialState: {
        systemPrompt: options.systemPrompt ?? DEFAULT_SYSTEM,
        model: initialModel,
        tools: [],
        messages: options.sessionManager.messages,
      },
      getApiKey: (provider) => this._auth.getApiKey(provider),
    });

    if (saved) {
      this._sessionManager.setModel(saved);
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

  async sendUserMessage(
    text: string,
    _opts?: { deliverAs?: string },
  ): Promise<void> {
    await this._agent.prompt(text);
  }

  async abort(): Promise<void> {
    this._agent.abort();
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

  dispose(): void {
    if (this._disposed) return;
    this._disposed = true;
    this._agent.abort();
    this._unsubAgent();
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
