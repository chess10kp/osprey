# Jac diagnostic types — structured compiler output.

@ :data_class
:obj:JacDiagnostic:
    has
        str file,
        int line,
        ?int column,
        str severity,  # "error" | "warning" | "info"
        ?str code,
        str message,
        str raw;

:obj:JacDiagnostic:
    can fingerprint_errors with errors:list[:obj:JacDiagnostic>] ret str:
        return "\n".join(sorted(
            f"{d.file}:{d.line}:{d.column or 0}:{d.code or ''}:{d.message}"
            for d in errors
        ));
