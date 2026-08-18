import from jaclang.compiler.js2jac.model {
    ConversionMode,
    ConversionRequest,
    ConversionResult,
    Js2jacDiagnostic,
    SourceInput
}
import from jaclang.compiler.js2jac.parser { parse_source }
import from jaclang.compiler.js2jac.convert { convert_envelope }
import from jaclang.compiler.js2jac.validate { validate_emitted }
import from jaclang.compiler.js2jac.report {
    build_emit_report,
    build_parse_report,
    merge_diagnostics
}


impl convert(request: ConversionRequest) -> ConversionResult {
    if not request.sources {
        return ConversionResult(
            ok=False,
            exit_code=1,
            diagnostics=[
                Js2jacDiagnostic(
                    code="E7401",
                    message="Conversion request has no source inputs",
                    category="project",
                    stage="pipeline",
                    blocking=True
                )
            ]
        );
    }
    all_ok = True;
    combined = ConversionResult(ok=True, exit_code=0);
    for source in request.sources {
        unit = _convert_one(request, source);
        combined.diagnostics.extend(unit.diagnostics);
        combined.report.diagnostics.extend(unit.report.diagnostics);
        combined.report.inputs.extend(unit.report.inputs);
        combined.report.outputs.extend(unit.report.outputs);
        combined.report.validation.extend(unit.report.validation);
        combined.report.summary.exact += unit.report.summary.exact;
        combined.report.summary.guarded += unit.report.summary.guarded;
        combined.report.summary.interop += unit.report.summary.interop;
        combined.report.summary.rejected += unit.report.summary.rejected;
        combined.report.summary.proposed += unit.report.summary.proposed;
        combined.emitted_files.update(unit.emitted_files);
        combined.dropped_exports.extend(unit.dropped_exports);
        if unit.report.parser_version {
            combined.report.parser_version = unit.report.parser_version;
        }
        if not unit.ok {
            all_ok = False;
        }
    }
    combined.ok = all_ok;
    combined.exit_code = 0 if all_ok else 1;
    return combined;
}


def _convert_one(request: ConversionRequest, source: SourceInput) -> ConversionResult {
    limits = request.config.parser_limits;
    parse_result = parse_source(source, limits);
    conv_report = build_parse_report(request, source, parse_result);
    if not parse_result.ok {
        return ConversionResult(
            ok=False,
            report=conv_report,
            diagnostics=parse_result.diagnostics,
            exit_code=1
        );
    }
    if request.config.mode == ConversionMode.PARSE_ONLY {
        return ConversionResult(ok=True, report=conv_report, diagnostics=[], exit_code=0);
    }
    if parse_result.envelope is None {
        return ConversionResult(
            ok=False,
            report=conv_report,
            diagnostics=[
                Js2jacDiagnostic(
                    code="E7101",
                    message="Parser succeeded without an envelope",
                    path=source.path,
                    category="protocol",
                    stage="parse",
                    blocking=True
                )
            ],
            exit_code=1
        );
    }
    emit_result = convert_envelope(
        parse_result.envelope,
        source,
        request.config.fail_open,
        request.config.external_dropped,
        request.config.emit_holes
    );
    if not emit_result.ok {
        conv_report.diagnostics.extend(emit_result.diagnostics);
        conv_report.summary.rejected += 1;
        return ConversionResult(
            ok=False,
            report=conv_report,
            diagnostics=emit_result.diagnostics,
            exit_code=1
        );
    }
    out_path = request.virtual_path_map.get(source.path, "");
    if not out_path {
        out_path = source.path;
        if out_path.endswith((".tsx", ".ts", ".jsx", ".js")) {
            out_path = out_path.rsplit(".", 1)[0] + ".jac";
        }
    }
    validation = validate_emitted(
        emit_result.jac_source,
        out_path,
        request.config.validation_level
    );
    conv_report = build_emit_report(
        request,
        source,
        parse_result,
        emit_result,
        validation,
        out_path
    );
    failed_validation = any(v.status == "failed" for v in validation);
    if failed_validation {
        return ConversionResult(
            ok=False,
            report=conv_report,
            diagnostics=[
                Js2jacDiagnostic(
                    code="E7207",
                    message="Emitted Jac failed validation",
                    path=source.path,
                    category="semantic",
                    stage="validate",
                    blocking=True,
                    help="See report validation stages for details"
                )
            ],
            exit_code=1
        );
    }
    return ConversionResult(
        ok=True,
        emitted_files={source.path: emit_result.jac_source},
        report=conv_report,
        diagnostics=[],
        exit_code=0,
        dropped_exports=emit_result.dropped_exports
    );
}
