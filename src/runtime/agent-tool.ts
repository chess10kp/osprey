import { Type } from "typebox";
import type { AgentTool } from "@earendil-works/pi-agent-core";
import type { Model, Api } from "@earendil-works/pi-ai";
import type { JackalAuth, JackalModels } from "./auth.js";
import type { DevMode } from "./dev-mode.js";
import { SubagentRunner, buildSubagentToolDescription } from "./subagent-runner.js";
import { wrapToolOutputLimit } from "./tool-output-limit.js";

export interface AgentToolContext {
  cwd: string;
  auth: JackalAuth;
  models: JackalModels;
  getParentModel: () => Model<Api>;
  getParentTools: () => AgentTool[];
  getMode: () => DevMode;
}

export function createAgentTool(ctx: AgentToolContext): AgentTool {
  return wrapToolOutputLimit({
    name: "agent",
    label: "Subagent",
    description: buildSubagentToolDescription(ctx.cwd),
    parameters: Type.Object({
      agent: Type.String({ description: "Subagent name (e.g. scout, architect, implementer)" }),
      prompt: Type.String({ description: "Task description for the subagent" }),
      chain: Type.Optional(Type.String({ description: "Optional saved chain name (e.g. pipeline)" })),
    }),
    execute: async (_toolCallId, rawParams) => {
      const params = rawParams as { agent: string; prompt: string; chain?: string };

      const runner = new SubagentRunner({
        cwd: ctx.cwd,
        auth: ctx.auth,
        models: ctx.models,
        parentModel: ctx.getParentModel(),
        parentTools: ctx.getParentTools(),
        mode: ctx.getMode(),
        getApiKey: (provider) => ctx.auth.getApiKey(provider),
      });

      const result = await runner.run({
        agentName: params.agent,
        prompt: params.prompt,
        chainName: params.chain,
      });

      if (result.error) {
        throw new Error(
          [
            `Subagent '${result.agent}' failed: ${result.error}`,
            result.summary ? `\nPartial output:\n${result.summary}` : "",
          ]
            .filter(Boolean)
            .join("\n"),
        );
      }

      const header = params.chain
        ? `Chain '${params.chain}' completed (${result.turns} turn(s), ${result.toolCallCount} tool call(s)).`
        : `Subagent '${result.agent}' completed (${result.turns} turn(s), ${result.toolCallCount} tool call(s)).`;

      return {
        content: [{ type: "text", text: `${header}\n\n${result.summary}` }],
        details: result,
      };
    },
  });
}
