import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import type { AgentTool } from "@earendil-works/pi-agent-core";
import { mcpInputSchemaToParameters, validateAndCoerceArgs } from "./mcp-schema.js";
import { wrapToolsOutputLimit } from "./tool-output-limit.js";

interface McpConfig {
  mcpServers?: Record<string, { command?: string; args?: string[] }>;
}

type ToolDef = { name: string; description?: string; inputSchema?: Record<string, unknown> };

export class JackalMcpClient {
  private _client: Client | null = null;
  private _transport: StdioClientTransport | null = null;
  private _serverName = "jac";
  private _cwd = "";
  private _command = "jac";
  private _args: string[] = ["mcp"];

  async connectFromConfig(cwd: string): Promise<boolean> {
    this._cwd = cwd;
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

    this._command = command;
    this._args = args;

    if (command === "jac" && args[0] === "mcp") {
      const probe = spawnSync("jac", ["mcp", "--help"], { encoding: "utf-8" });
      const stderr = probe.stderr || "";
      if (probe.status !== 0 && stderr.includes("invalid choice: 'mcp'")) {
        throw new Error(
          "Jac MCP is unavailable in this Jac CLI build (missing `jac mcp`). Use a Jac build with MCP support or update pi/mcp.json to a valid MCP server command.",
        );
      }
    }

    const transport = new StdioClientTransport({ command, args });
    const client = new Client({ name: "jackal-agent-next", version: "0.1.0" });
    await client.connect(transport);
    this._transport = transport;
    this._client = client;
    return true;
  }

  private async _reconnect(): Promise<void> {
    await this.disconnect().catch(() => undefined);
    const transport = new StdioClientTransport({ command: this._command, args: this._args });
    const client = new Client({ name: "jackal-agent-next", version: "0.1.0" });
    await client.connect(transport);
    this._transport = transport;
    this._client = client;
  }

  async listToolDefs(): Promise<ToolDef[]> {
    if (!this._client) return [];
    const res = await this._client.listTools();
    return (res.tools ?? []).map((t) => ({
      name: t.name,
      description: t.description,
      inputSchema: t.inputSchema as Record<string, unknown> | undefined,
    }));
  }

  toAgentTools(defs: ToolDef[]): AgentTool[] {
    return wrapToolsOutputLimit(
      defs.map((d) => ({
      name: d.name,
      label: `${this._serverName}:${d.name}`,
      description: d.description ?? `MCP tool ${d.name}`,
      parameters: mcpInputSchemaToParameters(d.inputSchema),
      execute: async (_toolCallId, rawParams) => {
        if (!this._client) throw new Error("MCP client not connected");
        const args = validateAndCoerceArgs(d.inputSchema, (rawParams ?? {}) as Record<string, unknown>);
        let result;
        try {
          result = await this._client.callTool({ name: d.name, arguments: args });
        } catch (error) {
          const msg = String(error);
          if (msg.includes("Connection closed")) {
            await this._reconnect();
            if (!this._client) throw error;
            result = await this._client.callTool({ name: d.name, arguments: args });
          } else {
            throw error;
          }
        }

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
        text = text || "(no output)";

        return {
          content: [{ type: "text", text }],
          details: result,
        };
      },
    })),
    );
  }

  async disconnect(): Promise<void> {
    if (!this._client) return;
    await this._client.close();
    this._client = null;
    this._transport = null;
  }
}
