import from jaclang.compiler.js2jac.model { ValidationLevel, ValidationStageResult }


def validate_emitted(
    jac_source: str,
    file_path: str,
    validation_level: ValidationLevel
) -> list[ValidationStageResult];
