import json;
import os;
import subprocess;

import jaclang;
import from jaclang.compiler.js2jac.model {
    Js2jacDiagnostic,
    ParserLimits,
    ParserResult,
    PARSER_PROTOCOL_VERSION,
    SourceInput
}
import from jaclang.compiler.js2jac.parser_schema { validate_parser_envelope }
import from jaclang.runtimelib.client.bun_installer { get_bun }


impl parser_bridge_path() -> str {
    return os.path.join(
        os.path.dirname(jaclang.__file__),
        "compiler",
        "js2jac",
        "parser_bridge.mjs"
    );
}


impl parse_source(source: SourceInput, limits: ParserLimits) -> ParserResult {
    encoded = source.source.encode("utf-8");
    if len(encoded) > limits.max_input_bytes {
        return ParserResult(
            ok=False,
            diagnostics=[
                Js2jacDiagnostic(
                    code="E7103",
                    message="Source exceeds max input bytes",
                    path=source.path,
                    category="protocol",
                    stage="parse",
                    blocking=True
                )
            ]
        );
    }
    bun = get_bun();
    if bun is None {
        return ParserResult(
            ok=False,
            diagnostics=[
                Js2jacDiagnostic(
                    code="E7104",
                    message="Bundled bun runtime is unavailable",
                    path=source.path,
                    category="protocol",
                    stage="parse",
                    blocking=True,
                    help="Run zig build fetch-bun or set JAC_BUN"
                )
            ]
        );
    }
    bridge = parser_bridge_path();
    if not os.path.isfile(bridge) {
        return ParserResult(
            ok=False,
            diagnostics=[
                Js2jacDiagnostic(
                    code="E7104",
                    message=f"Parser bridge not found at {bridge}",
                    path=source.path,
                    category="protocol",
                    stage="parse",
                    blocking=True
                )
            ]
        );
    }
    request = json.dumps(
        {
            "protocolVersion": PARSER_PROTOCOL_VERSION,
            "language": source.language.value,
            "source": source.source
        },
        ensure_ascii=False
    );
    try {
        completed = subprocess.run(
            [bun, bridge],
            input=request,
            capture_output=True,
            text=True,
            timeout=limits.timeout_seconds,
            check=False
        );
    } except subprocess.TimeoutExpired {
        return ParserResult(
            ok=False,
            diagnostics=[
                Js2jacDiagnostic(
                    code="E7103",
                    message="Parser subprocess timed out",
                    path=source.path,
                    category="protocol",
                    stage="parse",
                    blocking=True
                )
            ]
        );
    }
    stderr = completed.stderr or "";
    if len(stderr.encode("utf-8")) > limits.max_stderr_bytes {
        return ParserResult(
            ok=False,
            diagnostics=[
                Js2jacDiagnostic(
                    code="E7103",
                    message="Parser stderr exceeds size limit",
                    path=source.path,
                    category="protocol",
                    stage="parse",
                    blocking=True
                )
            ]
        );
    }
    if completed.returncode != 0 {
        return ParserResult(
            ok=False,
            diagnostics=[
                Js2jacDiagnostic(
                    code="E7104",
                    message=f"Parser bridge exited with code {completed.returncode}",
                    path=source.path,
                    category="protocol",
                    stage="parse",
                    blocking=True,
                    details={"stderr": stderr[:500]}
                )
            ]
        );
    }
    stdout = completed.stdout or "";
    try {
        payload = json.loads(stdout);
    } except json.JSONDecodeError as exc {
        return ParserResult(
            ok=False,
            diagnostics=[
                Js2jacDiagnostic(
                    code="E7101",
                    message=f"Parser bridge returned invalid JSON: {exc}",
                    path=source.path,
                    category="protocol",
                    stage="parse",
                    blocking=True
                )
            ]
        );
    }
    return validate_parser_envelope(payload, limits, stdout, path=source.path);
}
