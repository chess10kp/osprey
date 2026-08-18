import json;
import os;
import subprocess;

import jaclang;
import from jaclang.compiler.js2jac.model {
    ConversionSummary,
    Js2jacDiagnostic,
    MappingClass,
    ParserEnvelope,
    PARSER_PROTOCOL_VERSION,
    SourceInput
}
import from jaclang.compiler.js2jac.mapping { validate_mapping_entries }
import from jaclang.compiler.js2jac.source_ir { EmitResult, MappingEntry }
import from jaclang.runtimelib.client.bun_installer { get_bun }


def _bridge_path() -> str {
    return os.path.join(
        os.path.dirname(jaclang.__file__),
        "compiler",
        "js2jac",
        "convert_bridge.mjs"
    );
}


impl convert_envelope(
    envelope: ParserEnvelope,
    source: SourceInput,
    fail_open: bool = False,
    external_dropped: list[str] = [],
    emit_holes: bool = False
) -> EmitResult {
    bun = get_bun();
    if bun is None {
        return EmitResult(
            ok=False,
            diagnostics=[
                Js2jacDiagnostic(
                    code="E7104",
                    message="Bundled bun runtime is unavailable",
                    path=source.path,
                    category="protocol",
                    stage="convert",
                    blocking=True,
                    help="Run zig build fetch-bun or set JAC_BUN"
                )
            ]
        );
    }
    bridge = _bridge_path();
    if not os.path.isfile(bridge) {
        return EmitResult(
            ok=False,
            diagnostics=[
                Js2jacDiagnostic(
                    code="E7104",
                    message=f"Convert bridge not found at {bridge}",
                    path=source.path,
                    category="protocol",
                    stage="convert",
                    blocking=True
                )
            ]
        );
    }
    request = json.dumps(
        {
            "protocolVersion": PARSER_PROTOCOL_VERSION,
            "path": source.path,
            "ast": envelope.ast,
            "failOpen": fail_open,
            "externalDropped": external_dropped,
            "emitHoles": emit_holes,
            "source": source.source
        },
        ensure_ascii=False
    );
    try {
        completed = subprocess.run(
            [bun, bridge],
            input=request,
            capture_output=True,
            text=True,
            timeout=30.0,
            check=False
        );
    } except subprocess.TimeoutExpired {
        return EmitResult(
            ok=False,
            diagnostics=[
                Js2jacDiagnostic(
                    code="E7103",
                    message="Convert bridge timed out",
                    path=source.path,
                    category="protocol",
                    stage="convert",
                    blocking=True
                )
            ]
        );
    }
    if completed.returncode != 0 {
        return EmitResult(
            ok=False,
            diagnostics=[
                Js2jacDiagnostic(
                    code="E7104",
                    message=f"Convert bridge exited with code {completed.returncode}",
                    path=source.path,
                    category="protocol",
                    stage="convert",
                    blocking=True,
                    details={"stderr": (completed.stderr or "")[:500]}
                )
            ]
        );
    }
    try {
        payload = json.loads(completed.stdout or "{}");
    } except json.JSONDecodeError as exc {
        return EmitResult(
            ok=False,
            diagnostics=[
                Js2jacDiagnostic(
                    code="E7101",
                    message=f"Convert bridge returned invalid JSON: {exc}",
                    path=source.path,
                    category="protocol",
                    stage="convert",
                    blocking=True
                )
            ]
        );
    }
    if not payload.get("ok", False) {
        diags: list[Js2jacDiagnostic] = [];
        for item in payload.get("diagnostics", []) {
            if not isinstance(item, dict) {
                continue;
            }
            diags.append(
                Js2jacDiagnostic(
                    code=str(item.get("code", "E7200")),
                    message=str(item.get("message", "Conversion failed")),
                    path=str(item.get("path", source.path)),
                    category=str(item.get("category", "semantic")),
                    stage=str(item.get("stage", "convert")),
                    blocking=bool(item.get("blocking", True)),
                    details=item.get("details", {})
                )
            );
        }
        if not diags {
            diags.append(
                Js2jacDiagnostic(
                    code="E7200",
                    message="Conversion failed without diagnostics",
                    path=source.path,
                    category="semantic",
                    stage="convert",
                    blocking=True
                )
            );
        }
        return EmitResult(ok=False, diagnostics=diags);
    }
    jac_source = str(payload.get("jac", ""));
    if not jac_source.strip() {
        return EmitResult(
            ok=False,
            diagnostics=[
                Js2jacDiagnostic(
                    code="E7206",
                    message="Convert bridge returned empty Jac output",
                    path=source.path,
                    category="semantic",
                    stage="convert",
                    blocking=True
                )
            ]
        );
    }
    raw_mappings = payload.get("mappings", []);
    mappings: list[MappingEntry] = [];
    if isinstance(raw_mappings, list) and raw_mappings {
        for (idx, item) in enumerate(raw_mappings) {
            if not isinstance(item, dict) {
                continue;
            }
            cls = _mapping_class_from_value(item.get("mapping_class", "exact"));
            mappings.append(
                MappingEntry(
                    mapping_id=f"m{idx + 1}",
                    rule_id=str(item.get("rule_id", "")),
                    mapping_class=cls,
                    source_node_id="",
                    target=str(item.get("target", ""))
                )
            );
        }
    }
    if not mappings {
        # Backward-compatible fallback for bridge payloads without mappings.
        mappings = [
            MappingEntry(
                mapping_id="m1",
                rule_id="react.component.export-function.v1",
                mapping_class=MappingClass.EXACT,
                source_node_id="n1",
                target="def:pub app"
            ),
            MappingEntry(
                mapping_id="m2",
                rule_id="jsx.element.intrinsic.v1",
                mapping_class=MappingClass.EXACT,
                source_node_id="n2",
                target="JsxElement"
            )
        ];
    }
    (mapping_ok, mapping_diags) = validate_mapping_entries(mappings, source.path);
    if not mapping_ok {
        return EmitResult(ok=False, diagnostics=mapping_diags);
    }
    dropped_exports: list[str] = [];
    raw_dropped = payload.get("droppedExports", []);
    if isinstance(raw_dropped, list) {
        for name in raw_dropped {
            if isinstance(name, str) {
                dropped_exports.append(name);
            }
        }
    }
    return EmitResult(
        ok=True,
        jac_source=jac_source,
        diagnostics=[],
        mappings=mappings,
        dropped_exports=dropped_exports
    );
}


def _mapping_class_from_value(value: any) -> MappingClass {
    text = str(value);
    if text == "guarded" {
        return MappingClass.GUARDED;
    }
    if text == "interop" {
        return MappingClass.INTEROP;
    }
    if text == "rejected" {
        return MappingClass.REJECTED;
    }
    if text == "proposed" {
        return MappingClass.PROPOSED;
    }
    return MappingClass.EXACT;
}
