import from jaclang.compiler.js2jac.model { Js2jacDiagnostic, ParserEnvelope, SourceInput }
import from jaclang.compiler.js2jac.source_ir { NormalizeResult, NsirModule }


def normalize_ast(
    envelope: ParserEnvelope,
    source: SourceInput
) -> NormalizeResult;
