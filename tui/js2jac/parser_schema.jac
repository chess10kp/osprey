import from jaclang.compiler.js2jac.model {
    Js2jacDiagnostic,
    ParserEnvelope,
    ParserLimits,
    ParserResult
}


def validate_parser_envelope(
    payload: dict[str, any],
    limits: ParserLimits,
    raw_json: str,
    path: str = ""
) -> ParserResult;

def count_ast_nodes(ast_node: any, depth: int = 0) -> tuple[int, int];
