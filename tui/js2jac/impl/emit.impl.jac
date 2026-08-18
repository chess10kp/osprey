import from jaclang.compiler.js2jac.model { Js2jacDiagnostic, MappingClass }
import from jaclang.compiler.js2jac.source_ir {
    EmitResult,
    MappingEntry,
    NsirExportFunction,
    NsirJsxElement,
    NsirMemberAccess,
    NsirModule,
    NsirObjectType,
    NsirParameter
}


def _param_type_text(param: NsirParameter) -> str {
    if param.type_annotation is not None {
        props = [
            f"{prop.name}: {prop.jac_type}" for prop in param.type_annotation.properties
        ];
        return "{" + ", ".join(props) + "}";
    }
    return "dict";
}


def _member_access_text(access: NsirMemberAccess) -> str {
    return f"{access.object_name}.{access.property_name}";
}


def _jsx_children_text(element: NsirJsxElement) -> str {
    parts: list[str] = [];
    for child in element.children {
        parts.append("{" + _member_access_text(child) + "}");
    }
    return "".join(parts);
}


def _jsx_element_text(element: NsirJsxElement) -> str {
    return f"<{element.tag_name}>{_jsx_children_text(element)}</{element.tag_name}>";
}


def _function_text(func: NsirExportFunction) -> str {
    if not func.params {
        param_text = "";
    } else {
        param = func.params[0];
        param_text = f"{param.name}: {_param_type_text(param)}";
    }
    ret = func.body.statements[0].value;
    jsx_text = _jsx_element_text(ret);
    export_kw = ":pub " if func.exported else " ";
    return (
        f"def{export_kw}{func.name}({param_text}) -> {func.return_type} {{\n"
        f"    return {jsx_text};\n"
        f"}}"
    );
}


impl emit_module(module: NsirModule) -> EmitResult {
    if not module.exports {
        return EmitResult(
            ok=False,
            diagnostics=[
                Js2jacDiagnostic(
                    code="E7206",
                    message="Cannot emit empty module",
                    category="semantic",
                    stage="emit",
                    blocking=True
                )
            ]
        );
    }
    func = module.exports[0];
    jac_source = _function_text(func) + "\n";
    mappings = [
        MappingEntry(
            mapping_id="m1",
            rule_id="react.component.export-function.v1",
            mapping_class=MappingClass.EXACT,
            source_node_id=func.node.node_id,
            target=f"def:pub {func.name}"
        ),
        MappingEntry(
            mapping_id="m2",
            rule_id="jsx.element.intrinsic.v1",
            mapping_class=MappingClass.EXACT,
            source_node_id=func.body.statements[0].value.node.node_id,
            target="JsxElement"
        )
    ];
    return EmitResult(ok=True, jac_source=jac_source, diagnostics=[], mappings=mappings);
}
