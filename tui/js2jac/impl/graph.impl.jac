import os;
import re;

import from jaclang.compiler.js2jac.model { Js2jacDiagnostic }
import from jaclang.jac0core.helpers { read_file_with_encoding }


glob _SOURCE_EXTENSIONS: list[str] = [".ts", ".tsx", ".js", ".jsx"],
     _ASSET_IMPORT_EXTENSIONS: set[str] = {
         ".css",
         ".scss",
         ".sass",
         ".less",
         ".png",
         ".jpg",
         ".jpeg",
         ".gif",
         ".svg",
         ".webp",
         ".ico",
         ".woff",
         ".woff2",
         ".ttf",
         ".eot",
         ".mp4",
         ".webm"
     },
     _IMPORT_FROM_RE = re.compile(
         r"""(?x)
         \bimport\s+(?:type\s+)?
         (?:
             (?:\*\s+as\s+\w+)
             |(?:\w+)
             |(?:\{[^}]*\})
         )?
         \s+from\s+['"]([^'"]+)['"]
         """
     ),
     _IMPORT_SIDE_EFFECT_RE = re.compile(
         r"""\bimport\s+['"]([^'"]+)['"]"""
     ),
     _EXPORT_FROM_RE = re.compile(
         r"""(?x)
         \bexport\s+(?:type\s+)?
         (?:
             \*\s*(?:as\s+\w+\s+)?from
             |\{[^}]*\}\s+from
         )
         \s+['"]([^'"]+)['"]
         """
     ),
     _EXPORT_STAR_RE = re.compile(
         r"""\bexport\s+\*\s+from\s+['"]([^'"]+)['"]"""
     ),
     _REQUIRE_RE = re.compile(
         r"""\brequire\s*\(\s*['"]([^'"]+)['"]\s*\)"""
     ),
     _EXPORT_DECL_RE = re.compile(
         r"""(?x)
         \bexport\s+
         (?:
             (?:async\s+)?function\s+(\w+)
             |(?:const|let|var|class|enum|interface|type)\s+(\w+)
         )
         """
     ),
     _EXPORT_BRACE_RE = re.compile(
         r"""\bexport\s+\{([^}]+)\}(?:\s+from\s+['"][^'"]+['"])?"""
     ),
     _IMPORT_TYPE_NAMED_RE = re.compile(
         r"""(?x)
         \bimport\s+type\s+
         (?:
             \{([^}]+)\}
             |(\w+)
         )
         \s+from\s+['"]([^'"]+)['"]
         """
     ),
     _IMPORT_NAMED_RE = re.compile(
         r"""\bimport\s+\{([^}]+)\}\s+from\s+['"]([^'"]+)['"]"""
     ),
     _PROPS_TYPE_REF_RE = re.compile(
         r"""(?x)
         (?:
             \bprops\s*:\s*([A-Z]\w*)
             |\b(?:React\.)?FC\s*<\s*([A-Z]\w*)\s*>
             |\(\s*\{[^}]*\}\s*:\s*([A-Z]\w*)\s*\)
         )
         """
     );


def _normalize_rel_path(path: str) -> str {
    return path.replace(os.sep, "/").lstrip("./");
}


def _mask_comments(source: str) -> str {
    out: list[str] = [];
    i = 0;
    n = len(source);
    while i < n {
        ch = source[i];
        nxt = "";
        if i + 1 < n {
            nxt = source[i + 1];
        }
        if ch == "/" and nxt == "/" {
            while i < n and source[i] != "\n" {
                out.append(" ");
                i += 1;
            }
            continue;
        }
        if ch == "/" and nxt == "*" {
            out.append(" ");
            out.append(" ");
            i += 2;
            while i < n {
                if source[i] == "*" and i + 1 < n and source[i + 1] == "/" {
                    out.append(" ");
                    out.append(" ");
                    i += 2;
                    break;
                }
                out.append(" ");
                i += 1;
            }
            continue;
        }
        out.append(ch);
        i += 1;
    }
    return "".join(out);
}


def _default_basename(source_path: str) -> str {
    parts = [p for p in re.split(r"[\\/]", source_path) if p];
    base = parts[-1] if parts else "";
    base = re.sub(r"\.[^.]*$", "", base);
    if base == "index" {
        base = re.sub(r"\.[^.]*$", "", parts[-2]) if len(parts) >= 2 else "index";
    }
    base = re.sub(r"[^A-Za-z0-9_]", "", base);
    if not base {
        base = "Default";
    }
    if re.match(r"[0-9]", base) {
        base = "_" + base;
    }
    return base;
}


# V2.8: canonical symbol name a module exports as `default`, or "" if none.
# MUST mirror `defaultExportBasename`/the default-lowering in convert_bridge.mjs
# so `default as X` import rewrites resolve to the name that module emits.
def _default_export_symbol(source_path: str, masked: str) -> str {
    m = re.search(r"\bexport\s+default\s+(?:async\s+)?function\s+(\w+)", masked);
    if m is not None {
        return m.group(1);
    }
    m = re.search(r"\bexport\s+default\s+(\w+)\s*[;\n]", masked + "\n");
    if m is not None {
        name = m.group(1);
        if name not in {"function", "class", "async"} {
            return name;
        }
    }
    if re.search(r"\bexport\s+default\b", masked) is not None {
        return _default_basename(source_path);
    }
    return "";
}


def _parse_export_brace_names(raw: str) -> list[str] {
    names: list[str] = [];
    for part in raw.split(",") {
        item = part.strip();
        if not item {
            continue;
        }
        if " as " in item {
            (_, alias) = item.rsplit(" as ", 1);
            names.append(alias.strip());
        } else {
            names.append(item);
        }
    }
    return names;
}


# For a re-export brace `{ Widget, Label as Foo }`, return the local name (as
# exported by the target module) alongside the public name the barrel exposes.
# Parallel to _parse_export_brace_names, which returns only the public names.
def _parse_export_brace_pairs(raw: str) -> list[dict[str, str]] {
    pairs: list[dict[str, str]] = [];
    for part in raw.split(",") {
        item = part.strip();
        if not item {
            continue;
        }
        if " as " in item {
            (local, public) = item.rsplit(" as ", 1);
            pairs.append({"local": local.strip(), "public": public.strip()});
        } else {
            pairs.append({"local": item, "public": item});
        }
    }
    return pairs;
}


def _append_export_names(names: list[str], seen: dict[str, int], path: str, diags: list[Js2jacDiagnostic]) -> None {
    for name in names {
        if name in seen {
            diags.append(
                Js2jacDiagnostic(
                    code="E7406",
                    message=f"Duplicate export name '{name}'",
                    path=path,
                    category="project",
                    stage="graph",
                    blocking=True,
                    details={"exportName": name}
                )
            );
            continue;
        }
        seen[name] = 1;
    }
}


impl scan_module_surface(source_path: str, source: str) -> ModuleSurfaceScan {
    masked = _mask_comments(source);
    specifiers: list[dict[str, any]] = [];
    export_names: list[str] = [];
    star_export_count = 0;
    diagnostics: list[Js2jacDiagnostic] = [];
    export_seen: dict[str, int] = {};

    for match in _REQUIRE_RE.finditer(masked) {
        spec = match.group(1);
        diagnostics.append(
            Js2jacDiagnostic(
                code="E7409",
                message=f"CommonJS require is not supported in project mode: {spec}",
                path=source_path,
                category="project",
                stage="graph",
                blocking=True,
                details={"specifier": spec}
            )
        );
    }
    for match in _IMPORT_SIDE_EFFECT_RE.finditer(masked) {
        spec = match.group(1);
        if "from" in masked[max(0, match.start() - 12):match.start()] {
            continue;
        }
        specifiers.append(
            {"kind": ModuleEdgeKind.IMPORT.value, "specifier": spec}
        );
    }
    for match in _IMPORT_FROM_RE.finditer(masked) {
        specifiers.append(
            {"kind": ModuleEdgeKind.IMPORT.value, "specifier": match.group(1)}
        );
    }
    for match in _EXPORT_STAR_RE.finditer(masked) {
        star_export_count += 1;
        specifiers.append(
            {
                "kind": ModuleEdgeKind.STAR_REEXPORT.value,
                "specifier": match.group(1)
            }
        );
    }
    for match in _EXPORT_FROM_RE.finditer(masked) {
        spec = match.group(1);
        snippet = masked[match.start():match.end()];
        if "export *" in snippet or "export*" in snippet.replace(" ", "") {
            continue;
        }
        brace = re.search(r"\{([^}]+)\}\s+from", snippet);
        names: list[str] = [];
        locals: list[str] = [];
        if brace is not None {
            pairs = _parse_export_brace_pairs(brace.group(1));
            names = [p["public"] for p in pairs];
            locals = [p["local"] for p in pairs];
            _append_export_names(names, export_seen, source_path, diagnostics);
            export_names.extend(names);
        }
        specifiers.append(
            {
                "kind": ModuleEdgeKind.REEXPORT.value,
                "specifier": spec,
                "exportNames": names,
                "exportLocals": locals
            }
        );
    }
    for match in _EXPORT_DECL_RE.finditer(masked) {
        name = match.group(1) or match.group(2);
        if name {
            _append_export_names([name], export_seen, source_path, diagnostics);
            export_names.append(name);
        }
    }
    for match in _EXPORT_BRACE_RE.finditer(masked) {
        snippet = masked[match.start():match.end()];
        if " from " in snippet {
            continue;
        }
        names = _parse_export_brace_names(match.group(1));
        _append_export_names(names, export_seen, source_path, diagnostics);
        export_names.extend(names);
    }
    default_export_name = "";
    if re.search(r"\bexport\s+default\b", masked) {
        _append_export_names(["default"], export_seen, source_path, diagnostics);
        export_names.append("default");
        default_export_name = _default_export_symbol(source_path, masked);
    }
    return ModuleSurfaceScan(
        source_path=source_path,
        specifiers=specifiers,
        export_names=export_names,
        star_export_count=star_export_count,
        default_export_name=default_export_name,
        diagnostics=diagnostics
    );
}


impl is_reexport_only_module(source: str) -> bool {
    masked = _mask_comments(source);
    stripped = masked.strip();
    if not stripped {
        return False;
    }
    has_reexport = (
        _EXPORT_FROM_RE.search(masked) is not None
        or _EXPORT_STAR_RE.search(masked) is not None
    );
    if not has_reexport {
        return False;
    }
    if _EXPORT_DECL_RE.search(masked) is not None {
        return False;
    }
    for match in _EXPORT_BRACE_RE.finditer(masked) {
        snippet = masked[match.start():match.end()];
        if " from " not in snippet {
            return False;
        }
    }
    if _IMPORT_FROM_RE.search(masked) is not None {
        return False;
    }
    if _REQUIRE_RE.search(masked) is not None {
        return False;
    }
    return True;
}


def _resolution_candidates(base: str) -> list[str] {
    candidates: list[str] = [base];
    for ext in _SOURCE_EXTENSIONS {
        candidates.append(f"{base}{ext}");
        candidates.append(f"{base}/index{ext}");
    }
    return candidates;
}


impl resolve_local_specifier(
    specifier: str,
    from_path: str,
    known_sources: set[str]
) -> (str | None) {
    if not specifier.startswith(".") {
        return None;
    }
    from_dir = os.path.dirname(from_path);
    joined = _normalize_rel_path(
        os.path.normpath(os.path.join(from_dir, specifier))
    );
    for candidate in _resolution_candidates(joined) {
        if candidate in known_sources {
            return candidate;
        }
    }
    return None;
}


def _edge_key(edge_rec: dict[str, str]) -> str {
    return (
        f"{edge_rec.get('from', '')}|{edge_rec.get('to', '')}|{edge_rec.get('kind', '')}|"
        f"{edge_rec.get('specifier', '')}"
    );
}


def _append_edge(edges: list[dict[str, str]], seen: set[str], edge_rec: dict[str, str]) {
    key = _edge_key(edge_rec);
    if key in seen {
        return;
    }
    seen.add(key);
    edges.append(edge_rec);
}


def _tarjan_scc(adj: dict[str, list[str]]) -> list[list[str]] {
    index_state = [0];
    stack: list[str] = [];
    on_stack: set[str] = set();
    indices: dict[str, int] = {};
    lowlink: dict[str, int] = {};
    sccs: list[list[str]] = [];

    def strongconnect(vertex: str) {
        indices[vertex] = index_state[0];
        lowlink[vertex] = index_state[0];
        index_state[0] += 1;
        stack.append(vertex);
        on_stack.add(vertex);
        for neighbor in adj.get(vertex, []) {
            if neighbor not in indices {
                strongconnect(neighbor);
                lowlink[vertex] = min(lowlink[vertex], lowlink[neighbor]);
            } elif neighbor in on_stack {
                lowlink[vertex] = min(lowlink[vertex], indices[neighbor]);
            }
        }
        if lowlink[vertex] == indices[vertex] {
            component: list[str] = [];
            while True {
                w = stack.pop();
                on_stack.remove(w);
                component.append(w);
                if w == vertex {
                    break;
                }
            }
            component.sort();
            sccs.append(component);
        }
    }

    for vertex in sorted(adj.keys()) {
        if vertex not in indices {
            strongconnect(vertex);
        }
    }
    sccs.sort(key=lambda (comp: list[str]) { (len(comp), comp[0] if comp else "") });
    return sccs;
}


impl build_project_graph(
    project_root: str,
    convertible_paths: list[str]
) -> tuple[ProjectGraphPlan, list[Js2jacDiagnostic]] {
    diagnostics: list[Js2jacDiagnostic] = [];
    known_sources = set(convertible_paths);
    nodes = sorted(known_sources);
    edges: list[dict[str, str]] = [];
    edge_seen: set[str] = set();
    adj: dict[str, list[str]] = {node: [] for node in nodes};
    reexport_names: dict[str, dict[str, str]] = {};
    reexport_bindings: list[dict[str, str]] = [];
    star_reexports: dict[str, list[str]] = {};
    module_exports: dict[str, list[str]] = {};
    default_names: dict[str, str] = {};

    for source_path in sorted(convertible_paths) {
        abs_path = os.path.join(project_root, source_path);
        try {
            source = read_file_with_encoding(abs_path);
        } except OSError as exc {
            diagnostics.append(
                Js2jacDiagnostic(
                    code="E7401",
                    message=f"Unable to read source for graph scan: {exc}",
                    path=source_path,
                    category="project",
                    stage="graph",
                    blocking=True
                )
            );
            continue;
        }
        scan = scan_module_surface(source_path, source);
        diagnostics.extend(scan.diagnostics);
        if scan.default_export_name {
            default_names[source_path] = scan.default_export_name;
        }
        # Named (non-default) exports, used to disambiguate star-barrel bypass.
        named_exports = [n for n in scan.export_names if n != "default"];
        if named_exports {
            module_exports[source_path] = named_exports;
        }
        if source_path not in reexport_names {
            reexport_names[source_path] = {};
        }
        for spec_entry in scan.specifiers {
            specifier = spec_entry.get("specifier", "");
            kind = spec_entry.get("kind", ModuleEdgeKind.IMPORT.value);
            if not specifier.startswith(".") {
                continue;
            }
            target = resolve_local_specifier(
                specifier, source_path, known_sources
            );
            if target is None {
                (_, ext) = os.path.splitext(specifier);
                if ext.lower() in _ASSET_IMPORT_EXTENSIONS {
                    continue;
                }
                diagnostics.append(
                    Js2jacDiagnostic(
                        code="E7405",
                        message=f"Unresolved local import: {specifier}",
                        path=source_path,
                        category="project",
                        stage="graph",
                        blocking=True,
                        details={"specifier": specifier}
                    )
                );
                continue;
            }
            _append_edge(
                edges,
                edge_seen,
                {
                    "from": source_path,
                    "to": target,
                    "kind": kind,
                    "specifier": specifier
                }
            );
            if target not in adj[source_path] {
                adj[source_path].append(target);
            }
            if kind == ModuleEdgeKind.STAR_REEXPORT.value {
                if source_path not in star_reexports {
                    star_reexports[source_path] = [];
                }
                if target not in star_reexports[source_path] {
                    star_reexports[source_path].append(target);
                }
            }
            if kind == ModuleEdgeKind.REEXPORT.value {
                raw_names = spec_entry.get("exportNames", []);
                raw_locals = spec_entry.get("exportLocals", []);
                if isinstance(raw_names, list) {
                    for idx in range(len(raw_names)) {
                        export_name = str(raw_names[idx]);
                        local_name = (
                            str(raw_locals[idx])
                            if isinstance(raw_locals, list) and idx < len(raw_locals)
                            else export_name
                        );
                        prior = reexport_names[source_path].get(export_name);
                        if prior is not None and prior != target {
                            diagnostics.append(
                                Js2jacDiagnostic(
                                    code="E7406",
                                    message=(
                                        f"Conflicting re-export for '{export_name}' from "
                                        f"{prior} and {target}"
                                    ),
                                    path=source_path,
                                    category="project",
                                    stage="graph",
                                    blocking=True,
                                    details={
                                        "exportName": export_name,
                                        "firstTarget": prior,
                                        "secondTarget": target
                                    }
                                )
                            );
                        } else {
                            reexport_names[source_path][export_name] = target;
                            reexport_bindings.append(
                                {
                                    "barrel": source_path,
                                    "export": export_name,
                                    "local": local_name,
                                    "target": target
                                }
                            );
                        }
                    }
                }
            }
        }
    }
    for node in nodes {
        adj[node].sort();
    }
    edges.sort(
        key=lambda (edge_rec: dict[str, str]) {
            (
                edge_rec.get("from", ""),
                edge_rec.get("to", ""),
                edge_rec.get("kind", ""),
                edge_rec.get("specifier", "")
            );
        }
    );
    reexport_bindings.sort(
        key=lambda (rec: dict[str, str]) {
            (rec.get("barrel", ""), rec.get("export", ""), rec.get("target", ""));
        }
    );
    for barrel in star_reexports.keys() {
        star_reexports[barrel].sort();
    }
    for src in module_exports.keys() {
        module_exports[src].sort();
    }
    sccs = _tarjan_scc(adj);
    cyclic = [comp for comp in sccs if len(comp) > 1];
    return (
        ProjectGraphPlan(
            nodes=nodes,
            edges=edges,
            sccs=cyclic,
            default_export_names=default_names,
            reexport_bindings=reexport_bindings,
            star_reexports=star_reexports,
            module_exports=module_exports
        ),
        diagnostics
    );
}


def _parse_type_import_names(raw: str) -> list[str] {
    names: list[str] = [];
    for part in raw.split(",") {
        item = part.strip();
        if not item {
            continue;
        }
        if item.startswith("type ") {
            item = item[5:].strip();
        }
        if " as " in item {
            (_, alias) = item.rsplit(" as ", 1);
            names.append(alias.strip());
        } else {
            names.append(item);
        }
    }
    return names;
}


def _collect_local_type_imports(
    masked: str,
    source_path: str,
    known_sources: set[str]
) -> dict[str, str] {
    imported: dict[str, str] = {};
    for match in _IMPORT_TYPE_NAMED_RE.finditer(masked) {
        brace_names = match.group(1);
        default_name = match.group(2);
        specifier = match.group(3);
        if not specifier.startswith(".") {
            continue;
        }
        target = resolve_local_specifier(specifier, source_path, known_sources);
        if target is None {
            continue;
        }
        if default_name {
            imported[default_name] = target;
        }
        if brace_names {
            for name in _parse_type_import_names(brace_names) {
                imported[name] = target;
            }
        }
    }
    for match in _IMPORT_NAMED_RE.finditer(masked) {
        brace_names = match.group(1);
        specifier = match.group(2);
        if not specifier.startswith(".") {
            continue;
        }
        if "type " not in brace_names {
            continue;
        }
        target = resolve_local_specifier(specifier, source_path, known_sources);
        if target is None {
            continue;
        }
        for part in brace_names.split(",") {
            item = part.strip();
            if not item.startswith("type ") {
                continue;
            }
            name = item[5:].strip();
            if " as " in name {
                (_, alias) = name.rsplit(" as ", 1);
                imported[alias.strip()] = target;
            } else {
                imported[name] = target;
            }
        }
    }
    return imported;
}


def _collect_props_type_refs(masked: str) -> set[str] {
    refs: set[str] = set();
    for match in _PROPS_TYPE_REF_RE.finditer(masked) {
        for idx in range(1, 4) {
            name = match.group(idx);
            if name {
                refs.add(name);
            }
        }
    }
    return refs;
}


impl scan_cross_file_props_types(
    project_root: str,
    convertible_paths: list[str],
    known_sources: set[str]
) -> list[Js2jacDiagnostic] {
    diagnostics: list[Js2jacDiagnostic] = [];
    for source_path in sorted(convertible_paths) {
        abs_path = os.path.join(project_root, source_path);
        try {
            source = read_file_with_encoding(abs_path);
        } except OSError {
            continue;
        }
        masked = _mask_comments(source);
        type_imports = _collect_local_type_imports(
            masked, source_path, known_sources
        );
        if not type_imports {
            continue;
        }
        props_refs = _collect_props_type_refs(masked);
        for type_name in sorted(props_refs) {
            if type_name not in type_imports {
                continue;
            }
            diagnostics.append(
                Js2jacDiagnostic(
                    code="E7410",
                    message=(
                        f"Cross-file props type alias '{type_name}' is not supported; "
                        "use an inline object type in the component module"
                    ),
                    path=source_path,
                    category="project",
                    stage="graph",
                    blocking=True,
                    details={
                        "typeName": type_name,
                        "importedFrom": type_imports[type_name]
                    }
                )
            );
        }
    }
    return diagnostics;
}


impl scc_conversion_order(plan: ProjectGraphPlan) -> list[str] {
    nodes = plan.nodes;
    if not nodes {
        return [];
    }
    adj: dict[str, list[str]] = {node: [] for node in nodes};
    for edge in plan.edges {
        from_node = edge.get("from", "");
        to_node = edge.get("to", "");
        if from_node in adj and to_node in adj {
            if to_node not in adj[from_node] {
                adj[from_node].append(to_node);
            }
        }
    }
    for node in nodes {
        adj[node].sort();
    }
    all_sccs = _tarjan_scc(adj);
    node_to_scc: dict[str, int] = {};
    for (idx, comp) in enumerate(all_sccs) {
        for node in comp {
            node_to_scc[node] = idx;
        }
    }
    n_sccs = len(all_sccs);
    in_degree: dict[int, int] = {i: 0 for i in range(n_sccs)};
    cond_edges: dict[int, list[int]] = {i: [] for i in range(n_sccs)};
    for edge in plan.edges {
        from_node = edge.get("from", "");
        to_node = edge.get("to", "");
        if from_node not in node_to_scc or to_node not in node_to_scc {
            continue;
        }
        s_from = node_to_scc[from_node];
        s_to = node_to_scc[to_node];
        if s_from == s_to {
            continue;
        }
        if s_from not in cond_edges[s_to] {
            cond_edges[s_to].append(s_from);
            in_degree[s_from] += 1;
        }
    }
    for idx in range(n_sccs) {
        cond_edges[idx].sort();
    }
    ready: list[int] = [i for i in range(n_sccs) if in_degree[i] == 0];
    ready.sort();
    order: list[int] = [];
    while ready {
        current = ready.pop(0);
        order.append(current);
        for dependent in cond_edges[current] {
            in_degree[dependent] -= 1;
            if in_degree[dependent] == 0 {
                ready.append(dependent);
                ready.sort();
            }
        }
    }
    if len(order) != n_sccs {
        remaining = [i for i in range(n_sccs) if i not in order];
        remaining.sort();
        order.extend(remaining);
    }
    out: list[str] = [];
    for scc_idx in order {
        out.extend(sorted(all_sccs[scc_idx]));
    }
    return out;
}
