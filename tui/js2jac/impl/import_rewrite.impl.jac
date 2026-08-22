import os;
import re;

import from jaclang.compiler.js2jac.graph { resolve_local_specifier }


glob _JAC_IMPORT_FROM_RE = re.compile(
    r"""import from ("[^"]+"|\.[\w.]+) """
),
     _JAC_IMPORT_BRACE_RE = re.compile(r"""\{([^}]*)\}""");


def _normalize_rel_path(path: str) -> str {
    return path.replace(os.sep, "/").lstrip("./");
}


# V2.11 emits relative imports as native unquoted dotted specifiers
# (`.Button`, `..utils.helper`). Convert them to classic relative paths
# (`./Button`, `../utils/helper`) so resolution logic is form-agnostic.
def _import_specifier(raw: str) -> str {
    spec = raw.strip("\"'");
    # Only pure dotted forms (.x, ..a.b) are V2.11 normalized; quoted
    # relative paths pass through unchanged.
    import re as _re;

    if not _re.fullmatch(r"\.[\w.]+", spec) {
        return spec;
    }
    depth = 0;
    while depth < len(spec) and spec[depth] == "." {
        depth += 1;
    }
    rest = spec[depth:].strip(".");
    parts = [".."] * (depth - 1);
    if rest {
        parts.extend(rest.split("."));
    }
    rel = "/".join(parts);
    if not rel.startswith(".") {
        rel = "./" + rel;
    }
    return rel;
}


# Split a Jac import brace `{ Widget, Label as Foo }` into (imported, local)
# pairs: `imported` is the name the source module exposes, `local` the binding
# introduced here (equal when there is no `as`).
def _parse_jac_import_items(raw: str) -> list[dict[str, str]] {
    items: list[dict[str, str]] = [];
    for part in raw.split(",") {
        item = part.strip();
        if not item {
            continue;
        }
        if " as " in item {
            (imported, local) = item.rsplit(" as ", 1);
            items.append(
                {"imported": imported.strip(), "local": local.strip()}
            );
        } else {
            items.append({"imported": item, "local": item});
        }
    }
    return items;
}


def _format_jac_import_item(imported: str, local: str) -> str {
    return imported if imported == local else f"{imported} as {local}";
}


# Follow a named binding through one or more pure re-export barrels to the real
# module that defines it. Handles both explicit named re-exports
# (`barrel_map[barrel][export]` -> {"local", "target"}) and star re-exports
# (`star_map[barrel]` -> list of target sources, which forward every named,
# non-default export unchanged). Returns (target_source, local_name) once the
# chain lands on a non-barrel module, or None when a name is unresolved (came
# via an untracked path) or ambiguous (two star targets provide it).
def _resolve_through_barrels(
    barrel: str,
    export_name: str,
    barrel_map: dict[str, dict[str, dict[str, str]]],
    star_map: dict[str, list[str]],
    module_exports: dict[str, list[str]],
    default_names: dict[str, str],
    visited: set[str]
) -> (tuple[str, str] | None) {
    if barrel in visited {
        return None;
    }
    next_visited = set(visited);
    next_visited.add(barrel);

    # An explicit named re-export shadows any star re-export of the same name.
    binding = barrel_map.get(barrel, {}).get(export_name);
    if binding is not None {
        target = binding.get("target", "");
        local = binding.get("local", export_name);
        if target in barrel_map or target in star_map {
            # Follow the chain carrying the target's local name for this hop.
            return _resolve_through_barrels(
                target, local, barrel_map, star_map,
                module_exports, default_names, next_visited
            );
        }
        if local == "default" {
            local = default_names.get(target, "default");
        }
        return (target, local);
    }

    # Star fallback: `export * from './t'` forwards named (non-default) exports
    # unchanged. The name must resolve through exactly one star target to stay
    # unambiguous; zero or many candidates -> unresolved (caller keeps intact).
    candidates: list[tuple[str, str]] = [];
    seen_keys: set[str] = set();
    for star_target in star_map.get(barrel, []) {
        resolved = None;
        if star_target in barrel_map or star_target in star_map {
            resolved = _resolve_through_barrels(
                star_target, export_name, barrel_map, star_map,
                module_exports, default_names, next_visited
            );
        } elif export_name in module_exports.get(star_target, []) {
            resolved = (star_target, export_name);
        }
        if resolved is not None {
            key = f"{resolved[0]}|{resolved[1]}";
            if key not in seen_keys {
                seen_keys.add(key);
                candidates.append(resolved);
            }
        }
    }
    if len(candidates) == 1 {
        return candidates[0];
    }
    return None;
}


impl jac_relative_import(from_jac_path: str, to_jac_path: str) -> str {
    from_dir = os.path.dirname(from_jac_path);
    if not from_dir {
        from_dir = ".";
    }
    rel = os.path.relpath(to_jac_path, from_dir);
    rel = rel.replace(os.sep, "/");
    if not rel.startswith(".") {
        rel = f"./{rel}";
    }
    return rel;
}


# Rewrite a single Jac import line that resolves to a pure barrel into one line
# per real target module. Returns (new_lines, rewrite_records), or None when the
# line cannot be fully bypassed (no brace, or any name unresolved / pointing at
# a module that was not emitted) so the caller leaves the original line intact.
def _bypass_barrel_import(
    line: str,
    m: any,
    specifier: str,
    source_path: str,
    jac_path: str,
    barrel_source: str,
    barrel_map: dict[str, dict[str, dict[str, str]]],
    star_map: dict[str, list[str]],
    module_exports: dict[str, list[str]],
    source_to_jac: dict[str, str],
    default_names: dict[str, str]
) -> (tuple[list[str], list[dict[str, str]]] | None) {
    brace = _JAC_IMPORT_BRACE_RE.search(line, m.end(1));
    if brace is None {
        return None;
    }
    items = _parse_jac_import_items(brace.group(1));
    if not items {
        return None;
    }
    by_target: dict[str, list[str]] = {};
    for item in items {
        resolved = _resolve_through_barrels(
            barrel_source, item["imported"], barrel_map,
            star_map, module_exports, default_names, set()
        );
        if resolved is None {
            return None;
        }
        (target, target_local) = resolved;
        target_jac = source_to_jac.get(target, "");
        if not target_jac {
            return None;
        }
        jac_specifier = jac_relative_import(jac_path, target_jac);
        entry = _format_jac_import_item(target_local, item["local"]);
        if jac_specifier not in by_target {
            by_target[jac_specifier] = [];
        }
        by_target[jac_specifier].append(entry);
    }
    stripped = line.lstrip();
    indent = line[:len(line) - len(stripped)];
    newline = "";
    if line.endswith("\r\n") {
        newline = "\r\n";
    } elif line.endswith("\n") {
        newline = "\n";
    }
    new_lines: list[str] = [];
    rewrite_records: list[dict[str, str]] = [];
    for jac_specifier in sorted(by_target.keys()) {
        entries = sorted(by_target[jac_specifier]);
        body = ", ".join(entries);
        new_lines.append(
            indent + 'import from "' + jac_specifier + '" { ' + body + " }" + newline
        );
        rewrite_records.append(
            {
                "fromModule": specifier,
                "sourcePath": source_path,
                "toModule": jac_specifier
            }
        );
    }
    return (new_lines, rewrite_records);
}


impl build_import_rewrites(
    source_path: str,
    jac_path: str,
    jac_source: str,
    source_to_jac: dict[str, str],
    known_sources: set[str],
    default_names: dict[str, str] = {},
    reexport_bindings: list[dict[str, str]] = [],
    star_reexports: dict[str, list[str]] = {},
    module_exports: dict[str, list[str]] = {}
) -> tuple[str, list[dict[str, str]]] {
    rewrites: list[dict[str, str]] = [];
    seen: set[str] = set();
    out_lines: list[str] = [];

    # Index re-export bindings by barrel so imports that resolve to a pure
    # barrel (never emitted) can be rerouted straight to the real modules.
    barrel_map: dict[str, dict[str, dict[str, str]]] = {};
    for rec in reexport_bindings {
        barrel = rec.get("barrel", "");
        export_name = rec.get("export", "");
        if not barrel or not export_name {
            continue;
        }
        if barrel not in barrel_map {
            barrel_map[barrel] = {};
        }
        barrel_map[barrel][export_name] = {
            "local": rec.get("local", export_name),
            "target": rec.get("target", "")
        };
    }
    # A pure star-barrel produces no named bindings, so include star sources so
    # imports through them are still recognized as barrels to bypass.
    barrel_sources = set(barrel_map.keys());
    for star_barrel in star_reexports.keys() {
        barrel_sources.add(star_barrel);
    }

    for line in jac_source.splitlines(keepends=True) {
        m = _JAC_IMPORT_FROM_RE.search(line);
        if m is None {
            out_lines.append(line);
            continue;
        }
        specifier = _import_specifier(m.group(1));
        if not specifier.startswith(".") {
            out_lines.append(line);
            continue;
        }
        target_source = resolve_local_specifier(
            specifier, source_path, known_sources
        );
        if target_source is None {
            # The specifier may point at a pure barrel, which is inventoried
            # rather than emitted; bypass it to the real modules if we can.
            barrel_source = resolve_local_specifier(
                specifier, source_path, barrel_sources
            );
            bypass = None;
            if barrel_source is not None {
                bypass = _bypass_barrel_import(
                    line,
                    m,
                    specifier,
                    source_path,
                    jac_path,
                    barrel_source,
                    barrel_map,
                    star_reexports,
                    module_exports,
                    source_to_jac,
                    default_names
                );
            }
            if bypass is not None {
                (bypass_lines, bypass_rewrites) = bypass;
                out_lines.extend(bypass_lines);
                for rw in bypass_rewrites {
                    key = f"{rw['sourcePath']}|{rw['fromModule']}|{rw['toModule']}";
                    if key not in seen {
                        seen.add(key);
                        rewrites.append(rw);
                    }
                }
                continue;
            }
            out_lines.append(line);
            continue;
        }
        target_jac = source_to_jac.get(target_source, "");
        if not target_jac {
            out_lines.append(line);
            continue;
        }
        jac_specifier = jac_relative_import(jac_path, target_jac);
        new_line = line;
        if jac_specifier != specifier {
            key = f"{source_path}|{specifier}|{jac_specifier}";
            if key not in seen {
                seen.add(key);
                rewrites.append(
                    {
                        "fromModule": specifier,
                        "sourcePath": source_path,
                        "toModule": jac_specifier
                    }
                );
            }
            # Always re-emit the canonical quoted form, even when the input
            # used the V2.11 dotted style.
            new_line = (
                line[:m.start(1)]
                + '"' + jac_specifier + '"'
                + line[m.end(1):]
            );
        }
        # V2.8: a default import (`{ default as X }`) references the target
        # module's canonical default symbol; Jac has no `default` name, so
        # rewrite it to the name that module emits. Safe to apply after the
        # path edit above since the brace follows the specifier on the line.
        default_name = default_names.get(target_source, "");
        if default_name {
            new_line = re.sub(
                r"\bdefault as (\w+)",
                f"{default_name} as " + r"\1",
                new_line
            );
        }
        out_lines.append(new_line);
    }

    rewritten = "".join(out_lines);
    rewrites.sort(
        key=lambda (item: dict[str, str]) {
            (
                item.get("sourcePath", ""),
                item.get("fromModule", ""),
                item.get("toModule", "")
            );
        }
    );
    return (rewritten, rewrites);
}


impl build_virtual_path_map(source_to_jac: dict[str, str]) -> dict[str, str] {
    return dict(source_to_jac);
}


# Scan an emitted (pre-rewrite) Jac module for local imports whose *imported*
# name was dropped as a public export by the resolved upstream module. Returns
# the *local* binding names those imports introduce here, so the converter can
# re-run with them as `external_dropped` seeds (prune the import + drop any
# declaration that references the now-missing binding). Only direct local
# specifiers are resolved; barrel-routed imports fall through (the existing
# validate-and-prune backstop still guards those).
impl collect_dropped_import_locals(
    source_path: str,
    jac_source: str,
    known_sources: set[str],
    dropped_exports_by_source: dict[str, list[str]]
) -> list[str] {
    out: list[str] = [];
    seen: set[str] = set();
    for line in jac_source.splitlines() {
        m = _JAC_IMPORT_FROM_RE.search(line);
        if m is None {
            continue;
        }
        specifier = _import_specifier(m.group(1));
        if not specifier.startswith(".") {
            continue;
        }
        target_source = resolve_local_specifier(
            specifier, source_path, known_sources
        );
        if target_source is None {
            continue;
        }
        dropped = dropped_exports_by_source.get(target_source, []);
        if not dropped {
            continue;
        }
        brace = _JAC_IMPORT_BRACE_RE.search(line, m.end(1));
        if brace is None {
            continue;
        }
        for item in _parse_jac_import_items(brace.group(1)) {
            if item["imported"] in dropped and item["local"] not in seen {
                seen.add(item["local"]);
                out.append(item["local"]);
            }
        }
    }
    out.sort();
    return out;
}
