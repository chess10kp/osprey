"""Tool registry - native + js origins for the owned ReAct loop.

One lookup surface so Cordis `tools.*` fibers and the Pi JS host can both
contribute without a second source of truth. Native tools keep local handlers;
js tools carry schema only and dispatch through a PluginBridge.
"""


import from .tool_spec {
    ToolSpec,
}


obj RegisteredTool {
    has name: str = "",
        description: str = "",
        parameters: dict = {},
        origin: str = "native",
        extension_id: str = "",
        handler: Callable | None = None;
}


obj ToolRegistry {
    has tools: dict[str, RegisteredTool] = {};
}


def create_registry() -> ToolRegistry {
    return ToolRegistry();
}


"""Register or replace a native tool with a local callable handler."""
def register_native(
    reg: ToolRegistry,
    name: str,
    description: str,
    parameters: dict,
    handler: Callable,
) -> RegisteredTool {
    if not name {
        raise ValueError("tool name must not be empty");
    }
    if handler is None {
        raise ValueError("native tool requires a handler");
    }
    ent = RegisteredTool(
        name=name,
        description=description,
        parameters=parameters,
        origin="native",
        extension_id="",
        handler=handler,
    );
    reg.tools[name] = ent;
    return ent;
}


"""Register or replace a js-origin tool (schema only; invoke via bridge)."""
def register_js(
    reg: ToolRegistry,
    name: str,
    description: str,
    parameters: dict,
    extension_id: str,
) -> RegisteredTool {
    if not name {
        raise ValueError("tool name must not be empty");
    }
    if not extension_id {
        raise ValueError("js tool requires an extension_id");
    }
    ent = RegisteredTool(
        name=name,
        description=description,
        parameters=parameters,
        origin="js",
        extension_id=extension_id,
        handler=None,
    );
    reg.tools[name] = ent;
    return ent;
}


"""Seed the registry from an existing ToolSpec (native)."""
def register_native_spec(reg: ToolRegistry, spec: ToolSpec) -> RegisteredTool {
    if spec.handler is None {
        raise ValueError("native ToolSpec requires a handler");
    }
    return register_native(
        reg, spec.name, spec.description, spec.parameters, spec.handler
    );
}


def get_tool(reg: ToolRegistry, name: str) -> RegisteredTool | None {
    if name in reg.tools {
        return reg.tools[name];
    }
    return None;
}


def unregister(reg: ToolRegistry, name: str) -> bool {
    if name in reg.tools {
        del reg.tools[name];
        return True;
    }
    return False;
}


"""Drop every tool contributed by one extension. Returns count removed."""
def unregister_extension(reg: ToolRegistry, extension_id: str) -> int {
    doomed: list[str] = [];
    for (name, ent) in reg.tools.items() {
        if ent.extension_id == extension_id {
            doomed.append(name);
        }
    }
    for name in doomed {
        del reg.tools[name];
    }
    return len(doomed);
}


"""ToolSpecs for react_loop. Js entries have handler=None (invoke via bridge)."""
def as_tool_specs(reg: ToolRegistry) -> list[ToolSpec] {
    out: list[ToolSpec] = [];
    for (_name, ent) in reg.tools.items() {
        out.append(
            ToolSpec(
                name=ent.name,
                description=ent.description,
                parameters=ent.parameters,
                handler=ent.handler,
            )
        );
    }
    return out;
}


"""OpenAI-shape tool defs for the model (schema only, any origin)."""
def openai_tools(reg: ToolRegistry) -> list {
    defs = [];
    for (_name, ent) in reg.tools.items() {
        defs.append({
            "type": "function",
            "function": {
                "name": ent.name,
                "description": ent.description,
                "parameters": ent.parameters,
            },
        });
    }
    return defs;
}


"""Invoke a registered tool.

Native: call handler(**args).
Js: require `bridge` with invoke_js_tool(bridge, name, args) -> str.
Unknown / missing handler / missing bridge → ERROR string (loop-safe).
"""
def invoke(
    reg: ToolRegistry, name: str, args: dict, bridge: any = None
) -> str {
    ent = get_tool(reg, name);
    if ent is None {
        return f"ERROR: unknown tool {name}";
    }
    if ent.origin == "native" {
        if ent.handler is None {
            return f"ERROR: native tool {name} has no handler";
        }
        try {
            return str(ent.handler(**args));
        } except Exception as e {
            return f"ERROR: {e}";
        }
    }
    if ent.origin == "js" {
        if bridge is None {
            return f"ERROR: js tool {name} requires a plugin bridge";
        }
        try {
            return str(bridge.invoke_js_tool(name, args));
        } except Exception as e {
            return f"ERROR: {e}";
        }
    }
    return f"ERROR: unsupported tool origin {ent.origin}";
}
