"""Versioned js2jac mapping rule registry (catalog + validation)."""

import from jaclang.compiler.js2jac.model { Js2jacDiagnostic, MappingClass }
import from jaclang.compiler.js2jac.source_ir { MappingEntry, NsirKind }


obj MappingRule {
    has rule_id: str = "",
        version: str = "v1",
        mapping_class: MappingClass = MappingClass.EXACT,
        category: str = "",
        description: str = "",
        nsir_kinds: list[str] = [],
        guards: list[str] = [],
        enabled: bool = True,
        priority: int = 0;
}


obj MappingRegistry {
    has rule_set_version: str = "",
        schema_version: int = 1,
        rules: list[MappingRule] = [],
        rule_by_id: dict[str, MappingRule] = {},
        nsir_kind_coverage: dict[str, list[str]] = {};
}


def get_mapping_registry() -> MappingRegistry;

def validate_mapping_entries(
    entries: list[MappingEntry],
    path: str = ""
) -> tuple[bool, list[Js2jacDiagnostic]];

def check_nsir_kind_coverage(registry: MappingRegistry) -> tuple[bool, list[str]];

def check_rule_priority_stability(registry: MappingRegistry) -> tuple[bool, list[str]];

def nsir_kinds() -> list[str];
