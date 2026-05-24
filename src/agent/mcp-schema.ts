import { Type } from "typebox";
import type { TSchema } from "typebox";

const EMPTY_OBJECT_SCHEMA = { type: "object", properties: {} } as const;

/** Forward MCP JSON Schema to pi-agent (same approach as pi-mcp-adapter). */
export function mcpInputSchemaToParameters(schema?: Record<string, unknown>): TSchema {
  const jsonSchema =
    schema && typeof schema === "object" ? schema : (EMPTY_OBJECT_SCHEMA as Record<string, unknown>);
  return Type.Unsafe(jsonSchema as never);
}

export function coerceBySchema(value: unknown, schema: Record<string, unknown>): unknown {
  const t = schema.type;
  if (t === "string") return typeof value === "string" ? value : JSON.stringify(value);
  if (t === "number") {
    if (typeof value === "number") return value;
    const n = Number(value);
    if (!Number.isNaN(n)) return n;
    throw new Error(`Expected number, got ${String(value)}`);
  }
  if (t === "integer") {
    if (typeof value === "number" && Number.isInteger(value)) return value;
    const n = Number(value);
    if (Number.isInteger(n)) return n;
    throw new Error(`Expected integer, got ${String(value)}`);
  }
  if (t === "boolean") {
    if (typeof value === "boolean") return value;
    if (value === "true") return true;
    if (value === "false") return false;
    throw new Error(`Expected boolean, got ${String(value)}`);
  }
  if (t === "array") {
    if (Array.isArray(value)) return value;
    if (typeof value === "string") {
      const parsed = JSON.parse(value);
      if (Array.isArray(parsed)) return parsed;
    }
    throw new Error(`Expected array, got ${String(value)}`);
  }
  if (t === "object") {
    if (typeof value === "object" && value !== null) return value;
    if (typeof value === "string") {
      const parsed = JSON.parse(value);
      if (typeof parsed === "object" && parsed !== null) return parsed;
    }
    throw new Error(`Expected object, got ${String(value)}`);
  }
  return value;
}

export function validateAndCoerceArgs(
  schema: Record<string, unknown> | undefined,
  raw: Record<string, unknown>,
): Record<string, unknown> {
  if (!schema || schema.type !== "object") return raw;
  const props = (schema.properties ?? {}) as Record<string, Record<string, unknown>>;
  const required = Array.isArray(schema.required) ? schema.required.map(String) : [];
  const out: Record<string, unknown> = { ...raw };

  for (const key of required) {
    if (!(key in out)) throw new Error(`Missing required argument: ${key}`);
  }

  for (const [key, val] of Object.entries(out)) {
    const ps = props[key];
    if (!ps) continue;
    out[key] = coerceBySchema(val, ps);
  }

  return out;
}
