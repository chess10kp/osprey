import from jaclang.compiler.js2jac.model { Js2jacDiagnostic, ParserEnvelope, SourceInput }
import from jaclang.compiler.js2jac.source_ir { NormalizeResult }


"""Jac-side NSIR normalizer stub — V1 uses convert_bridge.mjs instead."""

impl normalize_ast(
    envelope: ParserEnvelope,
    source: SourceInput
) -> NormalizeResult {
    return NormalizeResult(
        ok=False,
        diagnostics=[
            Js2jacDiagnostic(
                code="E7200",
                message="Jac-side NSIR normalization is not wired in V1",
                path=source.path,
                category="semantic",
                stage="normalize",
                blocking=True,
                help="Use reviewed convert() which calls convert_bridge.mjs"
            )
        ]
    );
}
