"""Tool registry tests (merged with agent/registry.jac via same-stem annex).

Covers native/js registration, invoke routing, schema export, and extension teardown.
"""


def _echo(text: str) -> str {
    return "ECHO:" + text;
}


def _tool_echo(args: dict[str, any]) -> str {
    return _echo(str(args.get("text", "")));
}


def _boom(x: int) -> str {
    raise ValueError("boom");
}


def _tool_boom(args: dict[str, any]) -> str {
    return _boom(int(args.get("x", 0)));
}


test "register_native and get_tool" {
    reg = create_registry();
    ent = register_native(
        reg,
        "echo",
        "echo text",
        {
            "type": "object",
            "properties": {"text": {"type": "string"}},
            "required": ["text"],
        },
        _tool_echo,
    );
    assert ent.origin == "native";
    assert ent.handler is not None;
    got = get_tool(reg, "echo");
    assert got is not None;
    assert got.name == "echo";
}


test "register_js requires extension_id and has no handler" {
    reg = create_registry();
    ent = register_js(
        reg,
        "echo_js",
        "js echo",
        {"type": "object", "properties": {}},
        "ext.stub",
    );
    assert ent.origin == "js";
    assert ent.extension_id == "ext.stub";
    assert ent.handler is None;
    raised = False;
    try {
        register_js(reg, "bad", "d", {}, "");
    } except ValueError {
        raised = True;
    }
    assert raised;
}


test "invoke native success and error" {
    reg = create_registry();
    register_native(
        reg,
        "echo",
        "d",
        {"type": "object", "properties": {"text": {"type": "string"}}},
        _tool_echo,
    );
    register_native(
        reg,
        "boom",
        "d",
        {"type": "object", "properties": {"x": {"type": "integer"}}},
        _tool_boom,
    );
    assert invoke(reg, "echo", {"text": "hi"}) == "ECHO:hi";
    err = invoke(reg, "boom", {"x": 1});
    assert err.startswith("ERROR:");
    assert "boom" in err;
    assert invoke(reg, "missing", {}) == "ERROR: unknown tool missing";
}


test "invoke js without bridge returns error" {
    reg = create_registry();
    register_js(reg, "remote", "d", {}, "ext.a");
    out = invoke(reg, "remote", {});
    assert out.startswith("ERROR:");
    assert "bridge" in out;
}


test "as_tool_specs and openai_tools cover both origins" {
    reg = create_registry();
    register_native(
        reg,
        "echo",
        "d",
        {"type": "object", "properties": {"text": {"type": "string"}}},
        _tool_echo,
    );
    register_js(reg, "remote", "rd", {"type": "object"}, "ext.a");
    specs = as_tool_specs(reg);
    assert len(specs) == 2;
    names = [s.name for s in specs];
    assert "echo" in names;
    assert "remote" in names;
    defs = openai_tools(reg);
    assert len(defs) == 2;
    assert defs[0]["type"] == "function";
}


test "unregister and unregister_extension" {
    reg = create_registry();
    register_js(reg, "a", "d", {}, "ext.1");
    register_js(reg, "b", "d", {}, "ext.1");
    register_js(reg, "c", "d", {}, "ext.2");
    assert unregister(reg, "c");
    assert get_tool(reg, "c") is None;
    n = unregister_extension(reg, "ext.1");
    assert n == 2;
    assert get_tool(reg, "a") is None;
    assert get_tool(reg, "b") is None;
}
