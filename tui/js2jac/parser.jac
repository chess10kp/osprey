import from jaclang.compiler.js2jac.model {
    ParserLimits,
    ParserResult,
    SourceInput,
    SourceLanguage
}


def parse_source(source: SourceInput, limits: ParserLimits) -> ParserResult;

def parser_bridge_path() -> str;
