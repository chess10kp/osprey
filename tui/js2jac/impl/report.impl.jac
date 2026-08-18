import hashlib;
import json;

import from jaclang.compiler.js2jac.model {
    ConversionReport,
    ConversionRequest,
    ConversionResult,
    ConversionSummary,
    Js2jacDiagnostic,
    MappingClass,
    ParserResult,
    RULE_SET_VERSION,
    SourceInput,
    SourceRange,
    SourceSpan,
    ValidationStageResult
}
import from jaclang.compiler.js2jac.source_ir { EmitResult }


def _span_to_dict(span: SourceSpan) -> dict[str, int] {
    return {
        "byte": span.byte,
        "line": span.line,
        "utf16Column": span.utf16_column
    };
}


def _range_to_dict(src_range: SourceRange) -> dict[str, dict[str, int]] {
    return {
        "start": _span_to_dict(src_range.start),
        "end": _span_to_dict(src_range.end)
    };
}


impl diagnostic_to_dict(diag: Js2jacDiagnostic) -> dict[str, any] {
    out: dict[str, any] = {
        "code": diag.code,
        "severity": diag.severity,
        "category": diag.category,
        "stage": diag.stage,
        "message": diag.message,
        "help": diag.help,
        "blocking": diag.blocking,
        "nodeId": diag.node_id,
        "ruleId": diag.rule_id,
        "details": diag.details
    };
    if diag.path {
        out["source"] = {"path": diag.path};
        if diag.range is not None {
            out["source"]["start"] = _span_to_dict(diag.range.start);
            out["source"]["end"] = _span_to_dict(diag.range.end);
        }
    }
    return out;
}


impl build_parse_report(
    request: ConversionRequest,
    source: SourceInput,
    parse_result: ParserResult
) -> ConversionReport {
    digest = hashlib.sha256(source.source.encode("utf-8")).hexdigest();
    conv_report = ConversionReport(
        request_intent=request.config.intent.value,
        request_mode=request.config.mode.value,
        parser_protocol_version=1
    );
    conv_report.inputs = [
        {
            "path": source.path,
            "language": source.language.value,
            "sha256": f"sha256:{digest}",
            "bytes": len(source.source.encode("utf-8"))
        }
    ];
    if parse_result.envelope {
        conv_report.parser_name = parse_result.envelope.parser_name;
        conv_report.parser_version = parse_result.envelope.parser_version;
    }
    conv_report.diagnostics = parse_result.diagnostics;
    if parse_result.ok {
        conv_report.validation = [
            ValidationStageResult(stage="parse", status="passed", digest=digest)
        ];
    } else {
        conv_report.validation = [
            ValidationStageResult(stage="parse", status="failed", digest=digest)
        ];
    }
    return conv_report;
}


impl build_emit_report(
    request: ConversionRequest,
    source: SourceInput,
    parse_result: ParserResult,
    emit_result: EmitResult,
    validation: list[ValidationStageResult],
    output_path: str
) -> ConversionReport {
    conv_report = build_parse_report(request, source, parse_result);
    out_digest = hashlib.sha256(emit_result.jac_source.encode("utf-8")).hexdigest();
    conv_report.outputs = [
        {
            "path": output_path,
            "sha256": f"sha256:{out_digest}",
            "bytes": len(emit_result.jac_source.encode("utf-8"))
        }
    ];
    conv_report.validation = [
        ValidationStageResult(stage="parse", status="passed", digest=conv_report.validation[0].digest)
    ];
    conv_report.validation.extend(validation);
    summary = ConversionSummary();
    for m in emit_result.mappings {
        if m.mapping_class == MappingClass.EXACT {
            summary.exact += 1;
        } elif m.mapping_class == MappingClass.GUARDED {
            summary.guarded += 1;
        } elif m.mapping_class == MappingClass.INTEROP {
            summary.interop += 1;
        } elif m.mapping_class == MappingClass.REJECTED {
            summary.rejected += 1;
        } elif m.mapping_class == MappingClass.PROPOSED {
            summary.proposed += 1;
        }
    }
    conv_report.summary = summary;
    return conv_report;
}


impl merge_diagnostics(result: ConversionResult, extra: list[Js2jacDiagnostic]) -> None {
    result.diagnostics.extend(extra);
    result.report.diagnostics.extend(extra);
}


impl report_to_json(conv_report: ConversionReport) -> str {
    payload: dict[str, any] = {
        "schemaVersion": conv_report.schema_version,
        "ruleSetVersion": RULE_SET_VERSION,
        "request": {
            "intent": conv_report.request_intent,
            "mode": conv_report.request_mode
        },
        "inputs": conv_report.inputs,
        "outputs": conv_report.outputs,
        "summary": {
            "exact": conv_report.summary.exact,
            "guarded": conv_report.summary.guarded,
            "interop": conv_report.summary.interop,
            "rejected": conv_report.summary.rejected,
            "proposed": conv_report.summary.proposed
        },
        "diagnostics": [diagnostic_to_dict(d) for d in conv_report.diagnostics],
        "validation": [
            {"stage": v.stage, "status": v.status, "digest": v.digest}
            for v in conv_report.validation
        ],
        "parser": {
            "name": conv_report.parser_name,
            "version": conv_report.parser_version,
            "protocolVersion": conv_report.parser_protocol_version
        }
    };
    return json.dumps(payload, sort_keys=True, indent=2);
}
