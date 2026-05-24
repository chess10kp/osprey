import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import {
  mcpInputSchemaToParameters,
  validateAndCoerceArgs,
} from "../../src/agent/mcp-schema.js";

const cachePath = join(import.meta.dirname, "../../pi/mcp-cache.json");
const mcpCache = JSON.parse(readFileSync(cachePath, "utf-8")) as {
  servers?: { jac?: { tools?: Array<{ name: string; inputSchema?: Record<string, unknown> }> } };
};

function toolSchema(name: string): Record<string, unknown> | undefined {
  const tools = mcpCache.servers?.jac?.tools ?? [];
  return tools.find((t) => t.name === name)?.inputSchema;
}

describe("mcpInputSchemaToParameters", () => {
  it("forwards Jac MCP inputSchema including required fields", () => {
    const searchDocs = toolSchema("search_docs");
    expect(searchDocs).toBeDefined();

    const params = mcpInputSchemaToParameters(searchDocs) as Record<string, unknown>;
    expect(params.type).toBe("object");
    expect(params.required).toEqual(["query"]);
    expect((params.properties as Record<string, unknown>).query).toMatchObject({
      type: "string",
    });
  });

  it("forwards get_resource uri requirement", () => {
    const getResource = toolSchema("get_resource");
    expect(getResource).toBeDefined();

    const params = mcpInputSchemaToParameters(getResource) as Record<string, unknown>;
    expect(params.required).toEqual(["uri"]);
  });

  it("falls back to empty object schema when inputSchema is missing", () => {
    const params = mcpInputSchemaToParameters(undefined) as Record<string, unknown>;
    expect(params).toEqual({ type: "object", properties: {} });
  });
});

describe("validateAndCoerceArgs", () => {
  it("rejects empty args when query is required", () => {
    const schema = toolSchema("search_docs");
    expect(() => validateAndCoerceArgs(schema, {})).toThrow(
      "Missing required argument: query",
    );
  });

  it("accepts valid search_docs args", () => {
    const schema = toolSchema("search_docs");
    expect(validateAndCoerceArgs(schema, { query: "walker spawn" })).toEqual({
      query: "walker spawn",
    });
  });

  it("rejects empty args when uri is required", () => {
    const schema = toolSchema("get_resource");
    expect(() => validateAndCoerceArgs(schema, {})).toThrow(
      "Missing required argument: uri",
    );
  });
});
