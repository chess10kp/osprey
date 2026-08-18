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


def diagnostic_to_dict(diag: Js2jacDiagnostic) -> dict[str, any];

def build_parse_report(
    request: ConversionRequest,
    source: SourceInput,
    parse_result: ParserResult
) -> ConversionReport;

def build_emit_report(
    request: ConversionRequest,
    source: SourceInput,
    parse_result: ParserResult,
    emit_result: EmitResult,
    validation: list[ValidationStageResult],
    output_path: str
) -> ConversionReport;

def merge_diagnostics(result: ConversionResult, extra: list[Js2jacDiagnostic]) -> None;

def report_to_json(conv_report: ConversionReport) -> str;
