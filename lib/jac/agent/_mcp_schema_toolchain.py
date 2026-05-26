"""MCP JSON Schema ↔ parameter coercion.

Ported from src/agent/mcp-schema.ts. Pure data transformation — no typebox dependency.
"""

from __future__ import annotations

import json
from typing import Any


def mcp_input_schema_to_parameters(schema: dict | None) -> dict:
    """Forward MCP JSON Schema (passthrough — caller decides how to consume)."""
    if schema and isinstance(schema, dict):
        return schema
    return {"type": "object", "properties": {}}


def coerce_by_schema(value: Any, schema: dict) -> Any:
    """Coerce a single value according to JSON Schema type."""
    t = schema.get("type")
    if t == "string":
        return value if isinstance(value, str) else json.dumps(value)
    if t == "number":
        if isinstance(value, (int, float)):
            return value
        try:
            return float(value)
        except (TypeError, ValueError):
            raise ValueError(f"Expected number, got {value}")
    if t == "integer":
        if isinstance(value, int) and not isinstance(value, bool):
            return value
        try:
            n = int(value)
            return n
        except (TypeError, ValueError):
            raise ValueError(f"Expected integer, got {value}")
    if t == "boolean":
        if isinstance(value, bool):
            return value
        if value == "true":
            return True
        if value == "false":
            return False
        raise ValueError(f"Expected boolean, got {value}")
    if t == "array":
        if isinstance(value, list):
            return value
        if isinstance(value, str):
            parsed = json.loads(value)
            if isinstance(parsed, list):
                return parsed
        raise ValueError(f"Expected array, got {value}")
    if t == "object":
        if isinstance(value, dict):
            return value
        if isinstance(value, str):
            parsed = json.loads(value)
            if isinstance(parsed, dict):
                return parsed
        raise ValueError(f"Expected object, got {value}")
    return value


def validate_and_coerce_args(
    schema: dict | None, raw: dict,
) -> dict:
    """Validate and coerce raw tool arguments against a JSON Schema."""
    if not schema or schema.get("type") != "object":
        return raw
    props = schema.get("properties", {})
    required = schema.get("required", [])
    out = dict(raw)

    for key in required:
        if key not in out:
            raise ValueError(f"Missing required argument: {key}")

    for key, val in list(out.items()):
        ps = props.get(key)
        if not ps:
            continue
        out[key] = coerce_by_schema(val, ps)

    return out
