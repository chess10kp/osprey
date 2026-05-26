"""MCP JSON Schema parameter coercion — validate and coerce tool arguments."""

::py::
import json
from typing import Any


def mcp_input_schema_to_parameters(schema: dict | None) -> dict:
    if schema and isinstance(schema, dict):
        return schema
    return {"type": "object", "properties": {}}


def coerce_by_schema(value: Any, schema: dict) -> Any:
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
            return int(value)
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


def validate_and_coerce_args(schema: dict | None, raw: dict) -> dict:
    if not schema or schema.get("type") != "object":
        return raw
    props = schema.get("properties", {})
    required = schema.get("required", [])
    out = dict(raw)

    for key in required:
        if key not in out:
            raise ValueError(f"Missing required argument: {key}")

    for key in list(out.keys()):
        val = out[key]
        ps = props.get(key)
        if not ps:
            continue
        out[key] = coerce_by_schema(val, ps)

    return out
::py::

test "mcp schema none returns empty object" {
    result = mcp_input_schema_to_parameters(None);
    assert result["type"] == "object";
}

test "mcp schema passthrough" {
    schema = {"type": "object", "properties": {"q": {"type": "string"}}};
    assert mcp_input_schema_to_parameters(schema) == schema;
}

test "coerce string" {
    assert coerce_by_schema("hello", {"type": "string"}) == "hello";
    assert coerce_by_schema(42, {"type": "string"}) == "42";
}

test "coerce number" {
    assert coerce_by_schema(3.14, {"type": "number"}) == 3.14;
    assert coerce_by_schema("3.14", {"type": "number"}) == 3.14;
}

test "coerce integer" {
    assert coerce_by_schema(42, {"type": "integer"}) == 42;
    assert coerce_by_schema("42", {"type": "integer"}) == 42;
}

test "coerce boolean" {
    assert coerce_by_schema(True, {"type": "boolean"}) == True;
    assert coerce_by_schema("true", {"type": "boolean"}) == True;
    assert coerce_by_schema("false", {"type": "boolean"}) == False;
}

test "coerce array" {
    assert coerce_by_schema([1, 2], {"type": "array"}) == [1, 2];
    assert coerce_by_schema("[1,2]", {"type": "array"}) == [1, 2];
}

test "coerce object" {
    assert coerce_by_schema({"a": 1}, {"type": "object"}) == {"a": 1};
    assert coerce_by_schema('{"a":1}', {"type": "object"}) == {"a": 1};
}

test "coerce passthrough unknown type" {
    assert coerce_by_schema("anything", {"type": "unknown"}) == "anything";
}

test "validate and coerce" {
    schema = {
        "type": "object",
        "properties": {"count": {"type": "integer"}},
        "required": ["count"],
    };
    result = validate_and_coerce_args(schema, {"count": "42"});
    assert result["count"] == 42;
}

test "validate missing required" {
    schema = {"type": "object", "properties": {}, "required": ["name"]};
    try {
        validate_and_coerce_args(schema, {});
        assert False;
    } except ValueError as e {
        assert "Missing required" in str(e);
    }
}

test "validate no schema returns raw" {
    assert validate_and_coerce_args(None, {"a": 1}) == {"a": 1};
}
