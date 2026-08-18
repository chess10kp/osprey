import json;
import os;

import jaclang;
import from jaclang.compiler.js2jac.model {
    Js2jacDiagnostic,
    MappingClass,
    RULE_SET_VERSION
}
import from jaclang.compiler.js2jac.source_ir { MappingEntry, NsirKind }
import from jaclang.jac0core.helpers { read_file_with_encoding }


glob _REGISTRY_CACHE: (MappingRegistry | None) = None;


def _catalog_path() -> str {
    return os.path.join(
        os.path.dirname(jaclang.__file__),
        "compiler",
        "js2jac",
        "mapping_rules.json"
    );
}


def _mapping_class_from_text(text: str) -> MappingClass {
    if text == "guarded" {
        return MappingClass.GUARDED;
    }
    if text == "interop" {
        return MappingClass.INTEROP;
    }
    if text == "rejected" {
        return MappingClass.REJECTED;
    }
    if text == "proposed" {
        return MappingClass.PROPOSED;
    }
    return MappingClass.EXACT;
}


def _class_to_text(cls: MappingClass) -> str {
    if cls == MappingClass.GUARDED {
        return "guarded";
    }
    if cls == MappingClass.INTEROP {
        return "interop";
    }
    if cls == MappingClass.REJECTED {
        return "rejected";
    }
    if cls == MappingClass.PROPOSED {
        return "proposed";
    }
    return "exact";
}


def _load_mapping_registry() -> MappingRegistry {
    catalog_path = _catalog_path();
    assert os.path.isfile(catalog_path) , f"mapping catalog not found: {catalog_path}";
    raw_json = read_file_with_encoding(catalog_path);
    payload = json.loads(raw_json);
    assert isinstance(payload, dict) , "mapping catalog root must be a JSON object";
    rule_set_version = str(payload.get("rule_set_version", RULE_SET_VERSION));
    schema_version = int(payload.get("schema_version", 1));
    raw_rules = payload.get("rules", []);
    rules: list[MappingRule] = [];
    rule_by_id: dict[str, MappingRule] = {};
    if isinstance(raw_rules, list) {
        for item in raw_rules {
            if not isinstance(item, dict) {
                continue;
            }
            rule_id = str(item.get("rule_id", ""));
            if not rule_id {
                continue;
            }
            version_suffix = rule_id.rsplit(".", 1)[-1] if "." in rule_id else "v1";
            nsir_raw = item.get("nsir_kinds", []);
            nsir_kinds_list: list[str] = [];
            if isinstance(nsir_raw, list) {
                for kind in nsir_raw {
                    nsir_kinds_list.append(str(kind));
                }
            }
            guards_raw = item.get("guards", []);
            guards_list: list[str] = [];
            if isinstance(guards_raw, list) {
                for guard in guards_raw {
                    guards_list.append(str(guard));
                }
            }
            rule = MappingRule(
                rule_id=rule_id,
                version=version_suffix,
                mapping_class=_mapping_class_from_text(str(item.get("mapping_class", "exact"))),
                category=str(item.get("category", "")),
                description=str(item.get("description", "")),
                nsir_kinds=nsir_kinds_list,
                guards=guards_list,
                enabled=bool(item.get("enabled", True)),
                priority=int(item.get("priority", 0))
            );
            rules.append(rule);
            rule_by_id[rule_id] = rule;
        }
    }
    coverage_raw = payload.get("nsir_kind_coverage", {});
    coverage: dict[str, list[str]] = {};
    if isinstance(coverage_raw, dict) {
        for (kind, rule_ids) in coverage_raw.items() {
            ids: list[str] = [];
            if isinstance(rule_ids, list) {
                for rid in rule_ids {
                    ids.append(str(rid));
                }
            }
            coverage[str(kind)] = ids;
        }
    }
    return MappingRegistry(
        rule_set_version=rule_set_version,
        schema_version=schema_version,
        rules=rules,
        rule_by_id=rule_by_id,
        nsir_kind_coverage=coverage
    );
}


impl get_mapping_registry() -> MappingRegistry {
    if _REGISTRY_CACHE is None {
        _REGISTRY_CACHE = _load_mapping_registry();
    }
    return _REGISTRY_CACHE;
}


impl nsir_kinds() -> list[str] {
    return [
        NsirKind.MODULE.value,
        NsirKind.EXPORT_FUNCTION.value,
        NsirKind.PARAMETER.value,
        NsirKind.BLOCK.value,
        NsirKind.RETURN.value,
        NsirKind.JSX_ELEMENT.value,
        NsirKind.JSX_MEMBER_ACCESS.value,
        NsirKind.OBJECT_TYPE.value,
        NsirKind.TYPE_PROPERTY.value,
        NsirKind.STRING_TYPE.value
    ];
}


def _find_rule(registry: MappingRegistry, rule_id: str) -> (MappingRule | None) {
    if rule_id in registry.rule_by_id {
        return registry.rule_by_id[rule_id];
    }
    return None;
}


impl validate_mapping_entries(
    entries: list[MappingEntry],
    path: str = ""
) -> tuple[bool, list[Js2jacDiagnostic]] {
    registry = get_mapping_registry();
    diags: list[Js2jacDiagnostic] = [];
    for entry in entries {
        rule = _find_rule(registry, entry.rule_id);
        if rule is None {
            diags.append(
                Js2jacDiagnostic(
                    code="E7105",
                    message=f"Unknown mapping rule_id: {entry.rule_id}",
                    path=path,
                    category="protocol",
                    stage="convert",
                    blocking=True,
                    rule_id=entry.rule_id
                )
            );
            continue;
        }
        if not rule.enabled {
            diags.append(
                Js2jacDiagnostic(
                    code="E7105",
                    message=f"Disabled mapping rule referenced: {entry.rule_id}",
                    path=path,
                    category="protocol",
                    stage="convert",
                    blocking=True,
                    rule_id=entry.rule_id
                )
            );
            continue;
        }
        if rule.mapping_class != entry.mapping_class {
            diags.append(
                Js2jacDiagnostic(
                    code="E7105",
                    message=(
                        f"Mapping class mismatch for {entry.rule_id}: "
                        f"catalog={_class_to_text(rule.mapping_class)} "
                        f"entry={_class_to_text(entry.mapping_class)}"
                    ),
                    path=path,
                    category="protocol",
                    stage="convert",
                    blocking=True,
                    rule_id=entry.rule_id
                )
            );
        }
    }
    return (len(diags) == 0, diags);
}


impl check_nsir_kind_coverage(registry: MappingRegistry) -> tuple[bool, list[str]] {
    missing: list[str] = [];
    for kind in nsir_kinds() {
        rule_ids = registry.nsir_kind_coverage.get(kind, []);
        if not rule_ids {
            missing.append(kind);
            continue;
        }
        has_active = False;
        for rid in rule_ids {
            rule = _find_rule(registry, rid);
            if rule is not None and rule.enabled {
                has_active = True;
                break;
            }
        }
        if not has_active {
            missing.append(kind);
        }
    }
    return (len(missing) == 0, missing);
}


impl check_rule_priority_stability(registry: MappingRegistry) -> tuple[bool, list[str]] {
    conflicts: list[str] = [];
    seen: dict[str, MappingRule] = {};
    max_transform_priority = 0;
    for rule in registry.rules {
        if rule.rule_id in seen {
            conflicts.append(f"duplicate rule_id: {rule.rule_id}");
        }
        seen[rule.rule_id] = rule;
        if rule.enabled and rule.category != "catch-all" {
            max_transform_priority = max(max_transform_priority, rule.priority);
        }
    }
    for rule in registry.rules {
        if not rule.enabled or rule.category != "catch-all" {
            continue;
        }
        if rule.priority <= max_transform_priority {
            conflicts.append(
                f"catch-all {rule.rule_id} priority {rule.priority} "
                f"<= max transform priority {max_transform_priority}"
            );
        }
    }
    return (len(conflicts) == 0, conflicts);
}
