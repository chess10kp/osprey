"""Normalized Source IR (NSIR) — closed node families for js2jac V1."""

import from jaclang.compiler.js2jac.model { MappingClass }


enum NsirKind {
    MODULE = "module",
    EXPORT_FUNCTION = "export_function",
    PARAMETER = "parameter",
    BLOCK = "block",
    RETURN = "return",
    JSX_ELEMENT = "jsx_element",
    JSX_MEMBER_ACCESS = "jsx_member_access",
    OBJECT_TYPE = "object_type",
    TYPE_PROPERTY = "type_property",
    STRING_TYPE = "string_type"
}


obj NsirSpan {
    has byte_start: int = 0,
        byte_end: int = 0,
        line: int = 1,
        column: int = 0;
}


obj NsirNode {
    has node_id: str = "",
        kind: NsirKind = NsirKind.MODULE,
        span: NsirSpan = NsirSpan(),
        parent_id: str = "";
}


obj NsirTypeProperty {
    has name: str = "",
        jac_type: str = "",
        node: NsirNode = NsirNode();
}


obj NsirObjectType {
    has properties: list[NsirTypeProperty] = [],
        node: NsirNode = NsirNode();
}


obj NsirParameter {
    has name: str = "",
        type_annotation: (NsirObjectType | None) = None,
        node: NsirNode = NsirNode();
}


obj NsirMemberAccess {
    has object_name: str = "",
        property_name: str = "",
        node: NsirNode = NsirNode();
}


obj NsirJsxElement {
    has tag_name: str = "",
        children: list[NsirMemberAccess] = [],
        node: NsirNode = NsirNode();
}


obj NsirReturn {
    has value: (NsirJsxElement | None) = None,
        node: NsirNode = NsirNode();
}


obj NsirBlock {
    has statements: list[NsirReturn] = [],
        node: NsirNode = NsirNode();
}


obj NsirExportFunction {
    has name: str = "",
        exported: bool = True,
        params: list[NsirParameter] = [],
        body: (NsirBlock | None) = None,
        return_type: str = "JsxElement",
        node: NsirNode = NsirNode();
}


obj NsirModule {
    has source_id: str = "",
        exports: list[NsirExportFunction] = [],
        node_count: int = 0,
        node: NsirNode = NsirNode();
}


obj MappingEntry {
    has mapping_id: str = "",
        rule_id: str = "",
        mapping_class: MappingClass = MappingClass.EXACT,
        source_node_id: str = "",
        target: str = "";
}


obj NormalizeResult {
    has ok: bool = False,
        module: (NsirModule | None) = None,
        diagnostics: list = [],
        node_count: int = 0;
}


obj EmitResult {
    has ok: bool = False,
        jac_source: str = "",
        diagnostics: list = [],
        mappings: list[MappingEntry] = [],
        dropped_exports: list[str] = [];
}
