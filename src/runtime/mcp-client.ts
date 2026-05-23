import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { Type } from "typebox";
import type { AgentTool } from "@earendil-works/pi-agent-core";

interface McpConfig {
  mcpServers?: Record<string, { command?: string; args?: string[] }>;
}

export class JackalMcpClient {
  private _client: Client | null = null;
  private _serverName = "jac";

  async connectFromConfig(cwd: string): Promise<boolean> {
    const cfgPath = join(cwd, "pi", "mcp.json");
    let command = "jac";
    let args = ["mcp"];

    if (existsSync(cfgPath)) {
      try {
        const cfg = JSON.parse(readFileSync(cfgPath, "utf-8")) as McpConfig;
        const jac = cfg.mcpServers?.jac;
        if (jac?.command) command = jac.command;
        if (jac?.args?.length) args = jac.args;
      } catch {
        // ignore and use defaults
      }
    }

    const transport = new StdioClientTransport({ command, args });
    const client = new Client({ name: "jackal-agent-next", version: "0.1.0" });
    await client.connect(transport);
    this._client = client;
    return true;
  }

  async listToolDefs(): Promise<Array<{ name: string; description?: string; inputSchema?: Record<string, unknown> }>> {
    if (!this._client) return [];
    const res = await this._client.listTools();
    return (res.tools ?? []).map((t) => ({
      name: t.name,
      description: t.description,
      inputSchema: t.inputSchema as Record<string, unknown> | undefined,
    }));
  }

  toAgentTools(defs: Array<{ name: string; description?: string }>): AgentTool[] {
    return defs.map((d) => ({
      name: d.name,
      label: `${this._serverName}:${d.name}`,
      description: d.description ?? `MCP tool ${d.name}`,
      parameters: Type.Any(),
      execute: async (_toolCallId, rawParams) => {
        if (!this._client) throw new Error("MCP client not connected");
        const args = (rawParams ?? {}) as Record<string, unknown>;
        const result = await this._client.callTool({ name: d.name, arguments: args });

        let text = "";
        if (Array.isArray(result.content)) {
          text = result.content
            .map((c) => {
              const block = c as { type?: string; text?: string };
              if (block.type === "text") return block.text ?? "";
              return JSON.stringify(c);
            })
            .join("\n");
        }

        return {
          content: [{ type: "text", text: text || "(no output)" }],
          details: result,
        };
      },
    }));
  }

  async disconnect(): Promise<void> {
    if (!this._client) return;
    await this._client.close();
    this._client = null;
  }
}
