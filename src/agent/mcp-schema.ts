import { Type } from "typebox";
import type { TSchema } from "typebox";
import { bridgeMcpCoerceBySchema, bridgeMcpValidateAndCoerce } from "../jac/jac-bridge.js";

const EMPTY_OBJECT_SCHEMA = { type: "object", properties: {} } as const;

/** Forward MCP JSON Schema to pi-agent (same approach as pi-mcp-adapter). */
export function mcpInputSchemaToParameters(schema?: Record<string, unknown>): TSchema {
  const jsonSchema =
    schema && typeof schema === "object" ? schema : (EMPTY_OBJECT_SCHEMA as Record<string, unknown>);
  return Type.Unsafe(jsonSchema as never);
}

/** Coerce a value according to JSON Schema type — delegates to Python toolchain. */
export function coerceBySchema(value: unknown, schema: Record<string, unknown>): unknown {
  return bridgeMcpCoerceBySchema(value, schema);
}

/** Validate and coerce raw tool arguments against a JSON Schema — delegates to Python toolchain. */
export function validateAndCoerceArgs(
  schema: Record<string, unknown> | undefined,
  raw: Record<string, unknown>,
): Record<string, unknown> {
  return bridgeMcpValidateAndCoerce(schema, raw);
}
