"""One-time markup lowering to detached OSP graph construction (OSPUI.md §12).

Statically registered tag → archetype map. Unknown tag/property = error.
`--print-generated` emits equivalent direct-construction Jac. No virtual tree,
no per-frame view, no runtime archetype generation.
"""

import from ui.model {
    UiNode,
    MainScreen,
    Header,
    TranscriptView,
    Status,
    Prompt,
    ApprovalOverlay,
}


obj MarkupError {
    has path: str,
        message: str;
}


obj LowerResult {
    has graph_root: UiNode | None = None,
        errors: list[MarkupError] = [],
        generated_jac: str = "";
}


obj TagRegistry {
    has tags: dict[str, any] = {};
}


def create_tag_registry() -> TagRegistry {
    return TagRegistry();
}


"""Register a markup tag name to a node archetype constructor.

Helpers may accept known Jackal tags. Unknown registration is allowed for
Gate 5 external widgets.
"""
def register_tag(registry: TagRegistry, tag: str, archetype: any) {
    if not tag {
        raise ValueError("tag must not be empty");
    }
    registry.tags[tag] = archetype;
}


def default_shell_registry() -> TagRegistry {
    reg = create_tag_registry();
    register_tag(reg, "MainScreen", MainScreen);
    register_tag(reg, "Header", Header);
    register_tag(reg, "TranscriptView", TranscriptView);
    register_tag(reg, "Status", Status);
    register_tag(reg, "Prompt", Prompt);
    register_tag(reg, "ApprovalOverlay", ApprovalOverlay);
    return reg;
}


"""Lower markup source into a detached graph (one-time initialization).

Unit 12 implementation fills this in. Stub raises until then.
"""
def lower_markup(
    source: str,
    registry: TagRegistry | None = None,
    print_generated: bool = False,
) -> LowerResult {
    _ = (source, registry, print_generated);
    raise NotImplementedError("Unit 12: lower_markup");
}


"""Return generated Jac graph construction for markup (print-generated mode).

Unit 12 implementation fills this in. Stub raises until then.
"""
def print_generated(source: str, registry: TagRegistry | None = None) -> str {
    _ = (source, registry);
    raise NotImplementedError("Unit 12: print_generated");
}
