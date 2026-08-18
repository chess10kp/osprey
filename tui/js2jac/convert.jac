import from jaclang.compiler.js2jac.model {
    ConversionSummary,
    Js2jacDiagnostic,
    ParserEnvelope,
    SourceInput
}
import from jaclang.compiler.js2jac.source_ir { EmitResult, MappingEntry }


def convert_envelope(
    envelope: ParserEnvelope,
    source: SourceInput,
    fail_open: bool = False,
    external_dropped: list[str] = [],
    emit_holes: bool = False
) -> EmitResult;
