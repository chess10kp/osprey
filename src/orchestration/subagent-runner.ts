import { Agent, type AgentMessage, type AgentTool } from "@earendil-works/pi-agent-core";
import type { Model, Api } from "@earendil-works/pi-ai";
import type { JackalAuth, JackalModels } from "../auth/auth.js";
import type { DevMode } from "../agent/dev-mode.js";
import { isToolAllowedInPlanMode } from "../agent/dev-mode.js";
import { needsToolApproval } from "../agent/session-permissions.js";
import type { SessionPermissions } from "../agent/session-permissions.js";
import { getChain, listChains, type ChainDefinition, type ChainStep } from "./chains.js";
import {
  filterToolsForSubagent,
  getSubagent,
  listSubagents,
  normalizeAllowedToolNames,
  resolveSubagentModel,
  type SubagentDefinition,
} from "./subagents.js";

export const MAX_PARALLEL_SUBAGENTS = 5;

export interface SubagentRunResult {
  agent: string;
  summary: string;
  toolCallCount: number;
  turns: number;
  error?: string;
}

export interface SubagentRunnerDeps {
  cwd: string;
  auth: JackalAuth;
  models: JackalModels;
  parentModel: Model<Api>;
  parentTools: AgentTool[];
  mode: DevMode;
  sessionPermissions: SessionPermissions;
  alwaysAllow: ReadonlySet<string>;
  requestApproval: (
    toolCallId: string,
    toolName: string,
    params: Record<string, unknown>,
    subagentName: string,
  ) => Promise<boolean>;
  getApiKey: (provider: string) => Promise<string | undefined>;
}

export interface RunSubagentOptions {
  agentName: string;
  prompt: string;
  chainName?: string;
}

class ParallelLimiter {
  private _active = 0;
  private _queue: Array<() => void> = [];

  constructor(private readonly _max: number) {}

  get active(): number {
    return this._active;
  }

  async acquire(): Promise<void> {
    if (this._active < this._max) {
      this._active++;
      return;
    }

    await new Promise<void>((resolveP) => {
      this._queue.push(() => {
        this._active++;
        resolveP();
      });
    });
  }

  release(): void {
    this._active = Math.max(0, this._active - 1);
    const next = this._queue.shift();
    if (next) next();
  }
}

const globalLimiter = new ParallelLimiter(MAX_PARALLEL_SUBAGENTS);

function extractAssistantSummary(messages: AgentMessage[]): string {
  const parts: string[] = [];
  for (let i = messages.length - 1; i >= 0; i--) {
    const msg = messages[i];
    if (msg.role !== "assistant") continue;

    const content = (msg as { content?: unknown }).content;
    if (typeof content === "string" && content.trim()) {
      parts.unshift(content.trim());
      continue;
    }
    if (Array.isArray(content)) {
      const text = content
        .map((part) => {
          if (typeof part === "string") return part;
          if (part && typeof part === "object" && "text" in part) {
            return String((part as { text?: string }).text ?? "");
          }
          return "";
        })
        .join("\n")
        .trim();
      if (text) parts.unshift(text);
    }
  }

  return parts.join("\n\n").trim() || "(no subagent output)";
}

function countToolCalls(messages: AgentMessage[]): number {
  let count = 0;
  for (const msg of messages) {
    const content = (msg as { content?: unknown }).content;
    if (!Array.isArray(content)) continue;
    for (const part of content) {
      if (part && typeof part === "object" && "type" in part && (part as { type?: string }).type === "toolCall") {
        count++;
      }
    }
  }
  return count;
}

function substituteChainTemplate(
  template: string,
  vars: { task: string; previous: string },
): string {
  return template
    .replace(/\{task\}/g, vars.task)
    .replace(/\{previous\}/g, vars.previous);
}

function buildStepPrompt(step: ChainStep, vars: { task: string; previous: string }): string {
  let prompt = substituteChainTemplate(step.task, vars);

  if (step.reads?.length) {
    prompt = [
      "Read these artifacts from the prior step before continuing:",
      ...step.reads.map((file) => `- ${file}`),
      "",
      prompt,
    ].join("\n");
  }

  if (step.output) {
    prompt = [
      prompt,
      "",
      `Write your final answer for the next step as markdown suitable for '${step.output}'.`,
    ].join("\n");
  }

  return prompt;
}

export class SubagentRunner {
  private _deps: SubagentRunnerDeps;

  constructor(deps: SubagentRunnerDeps) {
    this._deps = deps;
  }

  async runSingle(
    agent: SubagentDefinition,
    prompt: string,
    stepModel?: string,
  ): Promise<SubagentRunResult> {
    if (globalLimiter.active >= MAX_PARALLEL_SUBAGENTS) {
      return {
        agent: agent.name,
        summary: "",
        toolCallCount: 0,
        turns: 0,
        error: `Maximum ${MAX_PARALLEL_SUBAGENTS} parallel subagents reached. Retry shortly.`,
      };
    }

    await globalLimiter.acquire();
    try {
      const model = resolveSubagentModel(
        agent,
        this._deps.parentModel,
        this._deps.models,
        this._deps.cwd,
        stepModel,
      );
      const allowed = normalizeAllowedToolNames(agent.tools);
      const tools = filterToolsForSubagent(this._deps.parentTools, allowed);
      const mode = this._deps.mode;

      const agentLoop = new Agent({
        initialState: {
          systemPrompt: agent.systemPrompt,
          model,
          tools,
          messages: [],
        },
        getApiKey: this._deps.getApiKey,
        beforeToolCall: async ({ toolCall, args }) => {
          const toolName = toolCall.name;
          const params =
            args && typeof args === "object" && !Array.isArray(args)
              ? (args as Record<string, unknown>)
              : {};

          if (mode === "plan" && !isToolAllowedInPlanMode(toolName)) {
            return {
              block: true,
              reason: `Tool "${toolName}" is blocked in plan mode for subagent "${agent.name}".`,
            };
          }

          if (
            !needsToolApproval(mode, toolName, params, {
              sessionPermissions: this._deps.sessionPermissions,
              alwaysAllow: this._deps.alwaysAllow,
            })
          ) {
            return undefined;
          }

          const approved = await this._deps.requestApproval(
            toolCall.id,
            toolName,
            params,
            agent.name,
          );

          if (!approved) {
            return {
              block: true,
              reason: `Tool "${toolName}" was rejected for subagent "${agent.name}".`,
            };
          }

          return undefined;
        },
      });

      await agentLoop.prompt(prompt);
      const messages = agentLoop.state.messages;
      const summary = extractAssistantSummary(messages);
      const toolCallCount = countToolCalls(messages);
      const turns = messages.filter((m) => m.role === "assistant").length;

      return {
        agent: agent.name,
        summary,
        toolCallCount,
        turns,
      };
    } catch (error) {
      return {
        agent: agent.name,
        summary: "",
        toolCallCount: 0,
        turns: 0,
        error: String(error),
      };
    } finally {
      globalLimiter.release();
    }
  }

  async runChain(chain: ChainDefinition, task: string): Promise<SubagentRunResult> {
    let previous = "";
    const summaries: string[] = [];
    let totalTools = 0;
    let totalTurns = 0;

    for (const [index, step] of chain.steps.entries()) {
      const agent = getSubagent(this._deps.cwd, step.agent);
      if (!agent) {
        return {
          agent: chain.name,
          summary: summaries.join("\n\n"),
          toolCallCount: totalTools,
          turns: totalTurns,
          error: `Chain step ${index + 1}: unknown agent '${step.agent}'`,
        };
      }

      const prompt = buildStepPrompt(step, { task, previous });
      const result = await this.runSingle(agent, prompt, step.model);
      totalTools += result.toolCallCount;
      totalTurns += result.turns;

      if (result.error) {
        return {
          agent: chain.name,
          summary: summaries.concat(result.summary).filter(Boolean).join("\n\n"),
          toolCallCount: totalTools,
          turns: totalTurns,
          error: `Chain step ${index + 1} (${step.agent}): ${result.error}`,
        };
      }

      summaries.push(`## ${step.agent}\n\n${result.summary}`);
      previous = result.summary;
    }

    return {
      agent: chain.name,
      summary: summaries.join("\n\n"),
      toolCallCount: totalTools,
      turns: totalTurns,
    };
  }

  async run(options: RunSubagentOptions): Promise<SubagentRunResult> {
    if (options.chainName) {
      const chain = getChain(this._deps.cwd, options.chainName);
      if (!chain) {
        return {
          agent: options.chainName,
          summary: "",
          toolCallCount: 0,
          turns: 0,
          error: `Unknown chain: ${options.chainName}`,
        };
      }
      return this.runChain(chain, options.prompt);
    }

    const agent = getSubagent(this._deps.cwd, options.agentName);
    if (!agent) {
      return {
        agent: options.agentName,
        summary: "",
        toolCallCount: 0,
        turns: 0,
        error: `Unknown subagent: ${options.agentName}`,
      };
    }

    return this.runSingle(agent, options.prompt);
  }
}

export function buildSubagentToolDescription(cwd: string): string {
  const agents = listSubagents(cwd);
  const chains = listChains(cwd);

  const agentLines = agents
    .slice(0, 12)
    .map((a) => `- ${a.name}: ${a.description}`)
    .join("\n");
  const chainLines = chains
    .slice(0, 8)
    .map((c) => `- ${c.name}: ${c.description}`)
    .join("\n");

  return [
    "Delegate a focused task to a specialized subagent in an isolated context.",
    "Only the final summary is returned. Up to 5 subagents may run in parallel.",
    "",
    "Available agents:",
    agentLines || "(none loaded)",
    "",
    "Available chains (pass as `chain`):",
    chainLines || "(none loaded)",
  ].join("\n");
}
