"""Typed contracts for js2jac conversion (schema version 1)."""

import os;

glob RULE_SET_VERSION: str = "js2jac-client-v1",
     REPORT_SCHEMA_VERSION: int = 1,
     PARSER_PROTOCOL_VERSION: int = 1;

enum SourceLanguage {
    JS = "js",
    TS = "ts",
    JSX = "jsx",
    TSX = "tsx"
}

enum MappingClass {
    EXACT = "exact",
    GUARDED = "guarded",
    INTEROP = "interop",
    REJECTED = "rejected",
    PROPOSED = "proposed"
}

enum ValidationLevel {
    PARSE = "parse",
    FORMAT = "format",
    CHECK = "check",
    CLIENT_COMPILE = "client-compile",
    DIFFERENTIAL = "differential"
}

enum ClientPlatform {
    WEB = "web",
    DESKTOP_WEBVIEW = "desktop-webview",
    MOBILE_WEBVIEW = "mobile-webview",
    MOBUI = "mobui"
}

enum ConversionIntent {
    CLIENT = "client"
}

enum ConversionMode {
    REVIEWED = "reviewed",
    PARSE_ONLY = "parse-only"
}

enum ClientFramework {
    REACT = "react",
    PREACT = "preact",
    SOLID = "solid",
    AUTO_REVIEWED = "auto-reviewed"
}

obj SourceSpan {
    has byte: int = 0,
        line: int = 1,
        utf16_column: int = 0;
}

obj SourceRange {
    has start: SourceSpan = SourceSpan(),
        end: SourceSpan = SourceSpan();
}

obj ParserLimits {
    has max_input_bytes: int = 1_048_576,
        max_ast_json_bytes: int = 32_777_216,
        max_node_count: int = 500_000,
        max_nesting_depth: int = 512,
        max_tokens: int = 500_000,
        max_comments: int = 100_000,
        timeout_seconds: float = 30.0,
        max_stderr_bytes: int = 65_536;
}

obj ConversionConfig {
    has intent: ConversionIntent = ConversionIntent.CLIENT,
        mode: ConversionMode = ConversionMode.REVIEWED,
        framework: ClientFramework = ClientFramework.REACT,
        platform: ClientPlatform = ClientPlatform.WEB,
        validation_level: ValidationLevel = ValidationLevel.CLIENT_COMPILE,
        parser_limits: ParserLimits = ParserLimits(),
        allow_interop: bool = True,
        semantic_tracks: list[str] = [],
        comments: str = "preserve",
        interop: str = "allow-reviewed",
        fail_open: bool = False,
        # LLM-cleanup hole mode: emit each dropped statement/declaration as a
        # `# JS2JAC-HOLE` comment carrying the original JS source, so a downstream
        # LLM pass sees the converted scaffold plus the unconverted holes in one
        # file. Only meaningful with fail_open; comments are inert (soundness and
        # the jac-check gate are unchanged).
        emit_holes: bool = False,
        # Local import names an upstream module dropped in fail-open project
        # mode. The converter prunes them from imports and drops any declaration
        # here that uses one (cross-file reference safety). Single-source use.
        external_dropped: list[str] = [];
}

obj SourceInput {
    has path: str = "",
        language: SourceLanguage = SourceLanguage.JS,
        source: str = "",
        source_id: str = "";
}

obj ConversionRequest {
    has sources: list[SourceInput] = [],
        config: ConversionConfig = ConversionConfig(),
        virtual_path_map: dict[str, str] = {};
}

obj Js2jacDiagnostic {
    has code: str = "",
        severity: str = "error",
        category: str = "internal",
        stage: str = "parse",
        message: str = "",
        help: str = "",
        blocking: bool = True,
        path: str = "",
        range: (SourceRange | None) = None,
        node_id: str = "",
        rule_id: str = "",
        details: dict[str, any] = {};
}

obj ConversionSummary {
    has exact: int = 0,
        guarded: int = 0,
        interop: int = 0,
        rejected: int = 0,
        proposed: int = 0;
}

obj ValidationStageResult {
    has stage: str = "",
        status: str = "skipped",
        digest: str = "";
}

obj ConversionReport {
    has schema_version: int = REPORT_SCHEMA_VERSION,
        rule_set_version: str = RULE_SET_VERSION,
        request_intent: str = "client",
        request_mode: str = "reviewed",
        inputs: list[dict[str, any]] = [],
        outputs: list[dict[str, any]] = [],
        summary: ConversionSummary = ConversionSummary(),
        diagnostics: list[Js2jacDiagnostic] = [],
        validation: list[ValidationStageResult] = [],
        parser_name: str = "@babel/parser",
        parser_version: str = "",
        parser_protocol_version: int = PARSER_PROTOCOL_VERSION;
}

obj ParserEnvelope {
    has protocol_version: int = 0,
        ok: bool = False,
        source_type: str = "",
        ast: dict[str, any] = {},
        tokens: list[dict[str, any]] = [],
        comments: list[dict[str, any]] = [],
        features: list[str] = [],
        parser_name: str = "",
        parser_version: str = "",
        diagnostics: list[dict[str, any]] = [],
        raw_json: str = "";
}

obj ParserResult {
    has ok: bool = False,
        envelope: (ParserEnvelope | None) = None,
        diagnostics: list[Js2jacDiagnostic] = [],
        node_count: int = 0,
        max_depth: int = 0;
}

obj ConversionResult {
    has ok: bool = False,
        emitted_files: dict[str, str] = {},
        report: ConversionReport = ConversionReport(),
        diagnostics: list[Js2jacDiagnostic] = [],
        exit_code: int = 1,
        # Public export names dropped during conversion (fail-open); consumed by
        # project mode to prune cross-file importers.
        dropped_exports: list[str] = [];
}

glob _SUFFIX_MAP: dict[str, SourceLanguage] = {
    ".js": SourceLanguage.JS,
    ".ts": SourceLanguage.TS,
    ".jsx": SourceLanguage.JSX,
    ".tsx": SourceLanguage.TSX
};


def language_from_suffix(path: str) -> (SourceLanguage | None) {
    (_, ext) = os.path.splitext(path);
    return _SUFFIX_MAP.get(ext.lower(), None);
}


def default_config() -> ConversionConfig {
    return ConversionConfig(
        intent=ConversionIntent.CLIENT,
        mode=ConversionMode.REVIEWED,
        framework=ClientFramework.REACT,
        platform=ClientPlatform.WEB,
        validation_level=ValidationLevel.CLIENT_COMPILE,
        parser_limits=ParserLimits(),
        allow_interop=True,
        semantic_tracks=[],
        comments="preserve",
        interop="allow-reviewed"
    );
}
