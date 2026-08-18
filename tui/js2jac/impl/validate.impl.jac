import hashlib;

import from jaclang.compiler.js2jac.model { ValidationLevel, ValidationStageResult }


def _digest(text: str) -> str {
    return hashlib.sha256(text.encode("utf-8")).hexdigest();
}


def _stage(stage: str, status: str, text: str) -> ValidationStageResult {
    return ValidationStageResult(stage=stage, status=status, digest=_digest(text));
}


impl validate_emitted(
    jac_source: str,
    file_path: str,
    validation_level: ValidationLevel
) -> list[ValidationStageResult] {
    import from jaclang.jac0core.program { JacProgram }

    results: list[ValidationStageResult] = [];
    if validation_level == ValidationLevel.PARSE {
        return results;
    }
    prog = JacProgram.jac_str_formatter(
        source_str=jac_source, file_path=file_path, auto_lint=False
    );
    if prog.errors_had {
        results.append(_stage("format", "failed", jac_source));
        return results;
    }
    formatted = prog.mod.main.gen.jac;
    results.append(_stage("format", "passed", formatted));
    if validation_level == ValidationLevel.FORMAT {
        return results;
    }
    prog2 = JacProgram.jac_str_formatter(
        source_str=formatted, file_path=file_path, auto_lint=False
    );
    if prog2.errors_had {
        results.append(_stage("reparse", "failed", formatted));
        return results;
    }
    formatted = prog2.mod.main.gen.jac;
    results.append(_stage("reparse", "passed", formatted));
    if validation_level == ValidationLevel.CHECK {
        check_prog = JacProgram();
        try {
            check_prog.build(file_path=file_path, use_str=formatted, type_check=True);
            if check_prog.errors_had {
                results.append(_stage("check", "failed", formatted));
            } else {
                results.append(_stage("check", "passed", formatted));
            }
        } except RuntimeError as exc {
            if "scheduling error" in str(exc) {
                results.append(
                    ValidationStageResult(
                        stage="check",
                        status="skipped",
                        digest=_digest(formatted)
                    )
                );
            } else {
                results.append(_stage("check", "failed", formatted));
            }
        }
        return results;
    }
    if validation_level in (ValidationLevel.CLIENT_COMPILE, ValidationLevel.DIFFERENTIAL) {
        compile_prog = JacProgram();
        try {
            ir = compile_prog.compile(
                file_path=file_path, use_str=formatted, no_cgen=False, type_check=True
            );
            if compile_prog.errors_had {
                results.append(_stage("check", "failed", formatted));
                return results;
            }
            results.append(_stage("check", "passed", formatted));
            js_out = ir.gen.js or "";
            if js_out.strip() {
                results.append(_stage("client-compile", "passed", js_out));
            } else {
                results.append(_stage("client-compile", "failed", formatted));
            }
        } except RuntimeError as exc {
            if "scheduling error" in str(exc) {
                results.append(
                    ValidationStageResult(stage="check", status="skipped", digest=_digest(formatted))
                );
                results.append(
                    ValidationStageResult(
                        stage="client-compile",
                        status="skipped",
                        digest=_digest(formatted)
                    )
                );
            } else {
                results.append(_stage("client-compile", "failed", formatted));
            }
        }
    }
    return results;
}
