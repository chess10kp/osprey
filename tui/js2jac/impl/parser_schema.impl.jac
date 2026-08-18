import from jaclang.compiler.js2jac.model {
    Js2jacDiagnostic,
    ParserEnvelope,
    ParserLimits,
    ParserResult,
    PARSER_PROTOCOL_VERSION
}


def _diag(
    code: str,
    message: str,
    path: str = "",
    category: str = "protocol",
    stage: str = "parse"
) -> Js2jacDiagnostic {
    return Js2jacDiagnostic(
        code=code,
        message=message,
        path=path,
        category=category,
        stage=stage,
        blocking=True
    );
}


impl count_ast_nodes(ast_node: any, depth: int = 0) -> tuple[int, int] {
    if ast_node is None {
        return (0, depth);
    }
    count = 1;
    max_depth = depth;
    if isinstance(ast_node, dict) {
        for value in ast_node.values() {
            (child_count, child_depth) = count_ast_nodes(value, depth + 1);
            count += child_count;
            max_depth = max(max_depth, child_depth);
        }
    } elif isinstance(ast_node, list) {
        for item in ast_node {
            (child_count, child_depth) = count_ast_nodes(item, depth + 1);
            count += child_count;
            max_depth = max(max_depth, child_depth);
        }
    }
    return (count, max_depth);
}


impl validate_parser_envelope(
    payload: dict[str, any],
    limits: ParserLimits,
    raw_json: str,
    path: str = ""
) -> ParserResult {
    diags: list[Js2jacDiagnostic] = [];
    if not isinstance(payload, dict) {
        diags.append(_diag("E7101", "Parser envelope must be a JSON object", path));
        return ParserResult(ok=False, diagnostics=diags);
    }
    if payload.get("protocolVersion") != PARSER_PROTOCOL_VERSION {
        diags.append(
            _diag(
                "E7101",
                f"Unsupported parser protocol version: {payload.get('protocolVersion')!r}",
                path
            )
        );
        return ParserResult(ok=False, diagnostics=diags);
    }
    if len(raw_json.encode("utf-8")) > limits.max_ast_json_bytes {
        diags.append(
            _diag("E7103", "Parser JSON response exceeds size limit", path)
        );
        return ParserResult(ok=False, diagnostics=diags);
    }
    parser_info = payload.get("parser", {});
    if not isinstance(parser_info, dict) {
        diags.append(_diag("E7101", "Parser metadata must be an object", path));
        return ParserResult(ok=False, diagnostics=diags);
    }
    if not payload.get("ok", False) {
        for item in payload.get("diagnostics", []) {
            if not isinstance(item, dict) {
                continue;
            }
            diags.append(
                Js2jacDiagnostic(
                    code=str(item.get("code", "E7102")),
                    message=str(item.get("message", "Parse failed")),
                    path=path,
                    category="syntax",
                    stage="parse",
                    blocking=True,
                    details={"reason": item.get("reason", "syntax_error")}
                )
            );
        }
        if not diags {
            diags.append(_diag("E7102", "Parser reported failure without diagnostics", path));
        }
        return ParserResult(ok=False, diagnostics=diags);
    }
    ast = payload.get("ast");
    if not isinstance(ast, dict) {
        diags.append(_diag("E7101", "Parser success response missing AST object", path));
        return ParserResult(ok=False, diagnostics=diags);
    }
    tokens = payload.get("tokens", []);
    comments = payload.get("comments", []);
    if not isinstance(tokens, list) {
        diags.append(_diag("E7101", "Parser tokens must be a list", path));
        return ParserResult(ok=False, diagnostics=diags);
    }
    if not isinstance(comments, list) {
        diags.append(_diag("E7101", "Parser comments must be a list", path));
        return ParserResult(ok=False, diagnostics=diags);
    }
    if len(tokens) > limits.max_tokens {
        diags.append(_diag("E7103", "Token count exceeds limit", path));
        return ParserResult(ok=False, diagnostics=diags);
    }
    if len(comments) > limits.max_comments {
        diags.append(_diag("E7103", "Comment count exceeds limit", path));
        return ParserResult(ok=False, diagnostics=diags);
    }
    (node_count, max_depth) = count_ast_nodes(ast);
    if node_count > limits.max_node_count {
        diags.append(_diag("E7103", "AST node count exceeds limit", path));
        return ParserResult(ok=False, diagnostics=diags);
    }
    if max_depth > limits.max_nesting_depth {
        diags.append(_diag("E7103", "AST nesting depth exceeds limit", path));
        return ParserResult(ok=False, diagnostics=diags);
    }
    envelope = ParserEnvelope(
        protocol_version=PARSER_PROTOCOL_VERSION,
        ok=True,
        source_type=str(payload.get("sourceType", "")),
        ast=ast,
        tokens=tokens,
        comments=comments,
        features=[str(f) for f in payload.get("features", []) if isinstance(f, str)],
        parser_name=str(parser_info.get("name", "@babel/parser")),
        parser_version=str(parser_info.get("version", "")),
        diagnostics=[],
        raw_json=raw_json
    );
    return ParserResult(
        ok=True,
        envelope=envelope,
        diagnostics=[],
        node_count=node_count,
        max_depth=max_depth
    );
}
