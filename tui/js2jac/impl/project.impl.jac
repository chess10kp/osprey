import hashlib;
import json;
import os;
import shutil;
import tempfile;
import datetime;

import from jaclang.compiler.js2jac.graph {
    ProjectGraphPlan,
    build_project_graph,
    is_reexport_only_module,
    scc_conversion_order,
    scan_cross_file_props_types
}
import from jaclang.compiler.js2jac.import_rewrite {
    build_import_rewrites,
    build_virtual_path_map,
    collect_dropped_import_locals
}
import from jaclang.compiler.js2jac.model {
    ConversionRequest,
    Js2jacDiagnostic,
    RULE_SET_VERSION,
    SourceInput,
    ValidationLevel,
    default_config,
    language_from_suffix
}
import from jaclang.compiler.js2jac.pipeline { convert }
import from jaclang.jac0core.helpers { path_matches_exclude, read_file_with_encoding }


glob _SOURCE_SUFFIXES: list[str] = [".js", ".jsx", ".ts", ".tsx"],
     _ASSET_SUFFIXES: list[str] = [
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
     ],
     _CONFIG_SUFFIXES: list[str] = [".json", ".toml", ".yaml", ".yml"],
     _VENDOR_DIR_NAMES: set[str] = {"node_modules", "vendor"},
     _GENERATED_DIR_NAMES: set[str] = {"dist", "build", ".next", "out", "coverage"},
     _PRUNE_DIR_NAMES: set[str] = {".git", ".jac", "node_modules"},
     _ENTRY_CANDIDATES: list[str] = [
         "src/index.tsx",
         "src/index.ts",
         "src/index.jsx",
         "src/index.js",
         "src/main.tsx",
         "src/main.ts",
         "src/App.tsx",
         "src/App.ts",
         "index.tsx",
         "index.ts"
     ],
     _FRAMEWORK_DEPS: dict[str, str] = {
         "react": "react",
         "preact": "preact",
         "@preact/preset-vite": "preact"
     };


def _normalize_rel_path(path: str) -> str {
    return path.replace(os.sep, "/").lstrip("./");
}


def _expand_brace_pattern(pattern: str) -> list[str] {
    start = pattern.find("{");
    if start < 0 {
        return [pattern];
    }
    end = pattern.find("}", start + 1);
    if end < 0 {
        return [pattern];
    }
    prefix = pattern[:start];
    suffix = pattern[end + 1:];
    options = pattern[start + 1:end].split(",");
    out: list[str] = [];
    for opt in options {
        out.extend(_expand_brace_pattern(prefix + opt + suffix));
    }
    return out;
}


def _expand_glob_patterns(patterns: list[str]) -> list[str] {
    expanded: list[str] = [];
    for pattern in patterns {
        expanded.extend(_expand_brace_pattern(pattern));
    }
    return expanded;
}


def _path_matches_glob(rel_path: str, patterns: list[str]) -> bool {
    return path_matches_exclude(
        rel_path, _expand_glob_patterns(patterns)
    );
}


def _is_same_or_child_path(child: str, parent: str) -> bool {
    child_abs = os.path.realpath(child);
    parent_abs = os.path.realpath(parent);
    try {
        common = os.path.commonpath([child_abs, parent_abs]);
    } except ValueError {
        return False;
    }
    return common == parent_abs;
}


def _read_ignore_file(path: str, base_rel: str) -> list[str] {
    if not os.path.isfile(path) {
        return [];
    }
    try {
        text = read_file_with_encoding(path);
    } except OSError {
        return [];
    }
    patterns: list[str] = [];
    for raw_line in text.splitlines() {
        line = raw_line.strip();
        if not line or line.startswith("#") {
            continue;
        }
        if line.startswith("!") {
            continue;
        }
        if line.startswith("/") {
            line = line[1:];
        }
        pattern: str = line;
        if base_rel {
            pattern = _normalize_rel_path(os.path.join(base_rel, line));
        } else {
            pattern = _normalize_rel_path(line);
        }
        patterns.append(pattern.rstrip("/"));
    }
    return patterns;
}


def _collect_ignore_patterns(project_root: str) -> list[str] {
    patterns: list[str] = [];
    patterns.extend(
        _read_ignore_file(os.path.join(project_root, ".gitignore"), "")
    );
    patterns.extend(
        _read_ignore_file(os.path.join(project_root, ".jacignore"), "")
    );
    for (dirpath, dirnames, _) in os.walk(
        project_root, topdown=True, followlinks=False
    ) {
        rel_dir = "";
        if dirpath != project_root {
            rel_dir = _normalize_rel_path(os.path.relpath(dirpath, project_root));
        }
        for skip_name in list(dirnames) {
            if skip_name in _PRUNE_DIR_NAMES {
                dirnames.remove(skip_name);
            }
        }
        if rel_dir {
            gitignore = os.path.join(dirpath, ".gitignore");
            patterns.extend(_read_ignore_file(gitignore, rel_dir));
        }
    }
    return patterns;
}


def _config_digest(config: ProjectDiscoveryConfig) -> str {
    payload = {
        "exclude": sorted(config.exclude),
        "include": sorted(config.include),
        "maxFileBytes": config.max_file_bytes
    };
    raw = json.dumps(payload, sort_keys=True, separators=(",", ":"));
    return f"sha256:{hashlib.sha256(raw.encode('utf-8')).hexdigest()}";
}


def _source_to_jac_path(rel_path: str) -> str {
    (base, _) = os.path.splitext(rel_path);
    return f"{base}.jac";
}


def _file_kind(rel_path: str, parts: list[str]) -> ProjectFileKind {
    for part in parts {
        if part in _VENDOR_DIR_NAMES {
            return ProjectFileKind.VENDOR;
        }
        if part in _GENERATED_DIR_NAMES {
            return ProjectFileKind.GENERATED;
        }
    }
    if rel_path.endswith(".d.ts") {
        return ProjectFileKind.DECLARATION;
    }
    (_, ext) = os.path.splitext(rel_path);
    ext_lower = ext.lower();
    if ext_lower in _ASSET_SUFFIXES {
        return ProjectFileKind.ASSET;
    }
    if ext_lower in _CONFIG_SUFFIXES {
        return ProjectFileKind.CONFIG;
    }
    return ProjectFileKind.SOURCE;
}


def _classify_entry(
    rel_path: str,
    kind: ProjectFileKind,
    config: ProjectDiscoveryConfig,
    ignore_patterns: list[str]
) -> ProjectFileStatus {
    if path_matches_exclude(rel_path, ignore_patterns) {
        return ProjectFileStatus.SKIP;
    }
    if kind == ProjectFileKind.VENDOR or kind == ProjectFileKind.GENERATED {
        return ProjectFileStatus.SKIP;
    }
    if rel_path.endswith(".d.ts") {
        return ProjectFileStatus.INVENTORY;
    }
    (_, ext) = os.path.splitext(rel_path);
    if kind == ProjectFileKind.ASSET or kind == ProjectFileKind.CONFIG {
        return ProjectFileStatus.SKIP;
    }
    language = language_from_suffix(rel_path);
    if language is None {
        return ProjectFileStatus.SKIP;
    }
    if _path_matches_glob(rel_path, config.exclude) {
        return ProjectFileStatus.SKIP;
    }
    if not _path_matches_glob(rel_path, config.include) {
        return ProjectFileStatus.SKIP;
    }
    return ProjectFileStatus.CONVERTIBLE;
}


def _sha256_file(abs_path: str) -> (str, int) {
    with open(abs_path, "rb") as in_f {
        data = in_f.read();
    }
    digest = hashlib.sha256(data).hexdigest();
    return (f"sha256:{digest}", len(data));
}


def _discover_files(
    project_root: str,
    config: ProjectDiscoveryConfig,
    ignore_patterns: list[str],
    diagnostics: list[Js2jacDiagnostic]
) -> list[ProjectFileEntry] {
    root_real = os.path.realpath(project_root);
    entries: list[ProjectFileEntry] = [];
    for (dirpath, dirnames, filenames) in os.walk(
        project_root, topdown=True, followlinks=False
    ) {
        rel_dir = "";
        if dirpath != project_root {
            rel_dir = _normalize_rel_path(os.path.relpath(dirpath, project_root));
        }
        pruned: list[str] = [];
        for dirname in dirnames {
            child_rel = dirname;
            if rel_dir {
                child_rel = f"{rel_dir}/{dirname}";
            }
            child_abs = os.path.join(dirpath, dirname);
            if dirname in _PRUNE_DIR_NAMES {
                continue;
            }
            if path_matches_exclude(child_rel, ignore_patterns) {
                continue;
            }
            if os.path.islink(child_abs) {
                link_real = os.path.realpath(child_abs);
                if not _is_same_or_child_path(link_real, root_real) {
                    diagnostics.append(
                        Js2jacDiagnostic(
                            code="E7403",
                            message=(
                                f"Symlink escapes project root: {child_rel}"
                            ),
                            path=child_rel,
                            category="project",
                            stage="discover",
                            blocking=True,
                            help="Remove or replace symlinks that point outside the project root"
                        )
                    );
                    continue;
                }
            }
            pruned.append(dirname);
        }
        dirnames[:] = pruned;
        for filename in sorted(filenames) {
            abs_path = os.path.join(dirpath, filename);
            rel_path = filename;
            if rel_dir {
                rel_path = f"{rel_dir}/{filename}";
            }
            rel_path = _normalize_rel_path(rel_path);
            if path_matches_exclude(rel_path, ignore_patterns) {
                continue;
            }
            if os.path.islink(abs_path) {
                link_real = os.path.realpath(abs_path);
                if not _is_same_or_child_path(link_real, root_real) {
                    diagnostics.append(
                        Js2jacDiagnostic(
                            code="E7403",
                            message=(
                                f"Symlink escapes project root: {rel_path}"
                            ),
                            path=rel_path,
                            category="project",
                            stage="discover",
                            blocking=True,
                            help="Remove or replace symlinks that point outside the project root"
                        )
                    );
                    continue;
                }
            }
            parts = [p for p in rel_path.split("/") if p];
            kind = _file_kind(rel_path, parts);
            status = _classify_entry(rel_path, kind, config, ignore_patterns);
            if (
                status == ProjectFileStatus.SKIP
                and kind != ProjectFileKind.SOURCE
                and kind != ProjectFileKind.DECLARATION
                and kind != ProjectFileKind.ASSET
                and kind != ProjectFileKind.CONFIG
            ) {
                continue;
            }
            if status == ProjectFileStatus.SKIP {
                if kind == ProjectFileKind.SOURCE {
                    language = language_from_suffix(rel_path);
                    if language is None {
                        continue;
                    }
                } elif (
                    kind != ProjectFileKind.DECLARATION
                    and kind != ProjectFileKind.ASSET
                    and kind != ProjectFileKind.CONFIG
                ) {
                    continue;
                }
            }
            (digest, nbytes) = _sha256_file(abs_path);
            if nbytes > config.max_file_bytes {
                diagnostics.append(
                    Js2jacDiagnostic(
                        code="E7401",
                        message=(
                            f"File exceeds max_file_bytes ({config.max_file_bytes}): "
                            f"{rel_path}"
                        ),
                        path=rel_path,
                        category="project",
                        stage="discover",
                        blocking=True
                    )
                );
                status = ProjectFileStatus.REJECT;
            }
            if (
                status == ProjectFileStatus.CONVERTIBLE
                and kind == ProjectFileKind.SOURCE
            ) {
                try {
                    source_text = read_file_with_encoding(abs_path);
                } except OSError {
                    source_text = "";
                }
                if is_reexport_only_module(source_text) {
                    status = ProjectFileStatus.INVENTORY;
                }
            }
            language = language_from_suffix(rel_path);
            jac_path = "";
            if language is not None {
                jac_path = _source_to_jac_path(rel_path);
            }
            entries.append(
                ProjectFileEntry(
                    source_path=rel_path,
                    jac_path=jac_path,
                    language=language.value if language is not None else "",
                    sha256=digest,
                    status=status,
                    kind=kind,
                    byte_size=nbytes
                )
            );
        }
    }
    entries.sort(
        key=lambda (item: ProjectFileEntry) { item.source_path; }
    );
    return entries;
}


def _detect_case_collisions(
    entries: list[ProjectFileEntry]
) -> list[Js2jacDiagnostic] {
    by_jac: dict[str, list[str]] = {};
    for entry in entries {
        if not entry.jac_path {
            continue;
        }
        key = entry.jac_path.lower();
        if key not in by_jac {
            by_jac[key] = [];
        }
        by_jac[key].append(entry.source_path);
    }
    diags: list[Js2jacDiagnostic] = [];
    for (jac_key, sources) in by_jac.items() {
        if len(sources) < 2 {
            continue;
        }
        unique = sorted(set(sources));
        if len(unique) < 2 {
            continue;
        }
        diags.append(
            Js2jacDiagnostic(
                code="E7404",
                message=(
                    f"Case-insensitive output collision for {jac_key}: "
                    f"{', '.join(unique)}"
                ),
                category="project",
                stage="plan",
                blocking=True,
                help="Rename sources so mapped Jac paths are unique on case-insensitive filesystems",
                details={"jacPath": jac_key, "sources": unique}
            )
        );
    }
    return diags;
}


def _validate_out_dir(project_root: str, out_dir: str) -> (Js2jacDiagnostic | None) {
    if not out_dir {
        return None;
    }
    root_abs = os.path.realpath(project_root);
    out_abs = os.path.realpath(out_dir);
    if _is_same_or_child_path(out_abs, root_abs) {
        return Js2jacDiagnostic(
            code="E7402",
            message="Output directory must not be inside the project root",
            category="project",
            stage="plan",
            blocking=True,
            help="Choose an out-dir outside the input tree or use a sibling directory",
            details={
                "projectRoot": _normalize_rel_path(root_abs),
                "outDir": _normalize_rel_path(out_abs)
            }
        );
    }
    return None;
}


def _write_emitted_tree(stage_root: str, emitted_files: dict[str, str]) -> None {
    for (jac_path, source) in emitted_files.items() {
        full = os.path.join(stage_root, jac_path);
        parent = os.path.dirname(full);
        if parent {
            os.makedirs(parent, exist_ok=True);
        }
        with open(full, "w", encoding="utf-8") as out_f {
            out_f.write(source);
        }
    }
}


def _validate_staged_project(
    stage_root: str,
    jac_paths: list[str]
) -> list[Js2jacDiagnostic] {
    import from jaclang.jac0core.program { JacProgram }

    diagnostics: list[Js2jacDiagnostic] = [];
    for jac_path in sorted(jac_paths) {
        abs_path = os.path.join(stage_root, jac_path);
        prog = JacProgram();
        try {
            prog.build(file_path=abs_path, type_check=True);
        } except RuntimeError as exc {
            if "scheduling error" not in str(exc) {
                diagnostics.append(
                    Js2jacDiagnostic(
                        code="E7411",
                        message=f"Project jac check failed for {jac_path}: {exc}",
                        path=jac_path,
                        category="project",
                        stage="validate",
                        blocking=True
                    )
                );
            }
            continue;
        }
        if prog.errors_had {
            diagnostics.append(
                Js2jacDiagnostic(
                    code="E7411",
                    message=f"Project jac check failed for {jac_path}",
                    path=jac_path,
                    category="project",
                    stage="validate",
                    blocking=True
                )
            );
        }
    }
    return diagnostics;
}


def _read_json_file(abs_path: str) -> (dict[str, any] | None) {
    if not os.path.isfile(abs_path) {
        return None;
    }
    try {
        with open(abs_path, "r", encoding="utf-8") as in_f {
            raw = in_f.read();
        }
    } except OSError {
        return None;
    }
    try {
        parsed = json.loads(raw);
    } except json.JSONDecodeError {
        return None;
    }
    if not isinstance(parsed, dict) {
        return None;
    }
    return parsed;
}


def _find_config_file(project_root: str, names: list[str]) -> (str | None) {
    for name in names {
        candidate = os.path.join(project_root, name);
        if os.path.isfile(candidate) {
            return candidate;
        }
    }
    return None;
}


def _package_name(pkg: dict[str, any]) -> str {
    raw = pkg.get("name", "");
    if not isinstance(raw, str) or not raw.strip() {
        return "converted-app";
    }
    name = raw.strip();
    if name.startswith("@") {
        parts = name.split("/");
        if len(parts) == 2 {
            return parts[1] or "converted-app";
        }
    }
    return name;
}


def _detect_framework(deps: dict[str, any]) -> str {
    for (pkg_name, framework) in _FRAMEWORK_DEPS.items() {
        if pkg_name in deps {
            return framework;
        }
    }
    return "react";
}


def _detect_entry_jac(
    pkg: dict[str, any],
    convertible_by_source: dict[str, ProjectFileEntry]
) -> str {
    for field in ["main", "module", "source"] {
        raw = pkg.get(field, "");
        if not isinstance(raw, str) or not raw.strip() {
            continue;
        }
        rel = _normalize_rel_path(raw);
        if rel.endswith(".jac") {
            return rel;
        }
        jac_candidate = _source_to_jac_path(rel);
        if jac_candidate in {e.jac_path for e in convertible_by_source.values()} {
            return jac_candidate;
        }
        if rel in convertible_by_source {
            return convertible_by_source[rel].jac_path;
        }
    }
    for candidate in _ENTRY_CANDIDATES {
        if candidate in convertible_by_source {
            return convertible_by_source[candidate].jac_path;
        }
    }
    for file_entry in sorted(
        convertible_by_source.values(),
        key=lambda (e: ProjectFileEntry) { e.source_path; }
    ) {
        if file_entry.jac_path {
            return file_entry.jac_path;
        }
    }
    return "";
}


def _normalize_ts_path_target(target: str) -> str {
    value = target.strip();
    if value.startswith("./") {
        return value;
    }
    if value.startswith("/") {
        return f".{value}";
    }
    return f"./{value}";
}


def _extract_tsconfig_paths(
    tsconfig: dict[str, any],
    diagnostics: list[Js2jacDiagnostic]
) -> dict[str, str] {
    compiler = tsconfig.get("compilerOptions", {});
    if not isinstance(compiler, dict) {
        return {};
    }
    raw_paths = compiler.get("paths", {});
    if not isinstance(raw_paths, dict) or not raw_paths {
        return {};
    }
    mapped: dict[str, str] = {};
    for (alias, targets) in sorted(raw_paths.items()) {
        if not isinstance(alias, str) or not alias {
            continue;
        }
        if not isinstance(targets, list) or not targets {
            diagnostics.append(
                Js2jacDiagnostic(
                    code="E7412",
                    message=f"Unsupported tsconfig path alias (no targets): {alias}",
                    category="project",
                    stage="plan",
                    blocking=False,
                    details={"alias": alias},
                    help="Add an explicit [client.paths] mapping in jac.toml after conversion"
                )
            );
            continue;
        }
        if len(targets) != 1 {
            diagnostics.append(
                Js2jacDiagnostic(
                    code="E7412",
                    message=(
                        f"Unsupported tsconfig path alias (multiple targets): {alias}"
                    ),
                    category="project",
                    stage="plan",
                    blocking=False,
                    details={"alias": alias, "targets": targets},
                    help="Collapse to a single target or map manually in jac.toml"
                )
            );
            continue;
        }
        target = targets[0];
        if not isinstance(target, str) or not target {
            continue;
        }
        mapped[alias] = _normalize_ts_path_target(target);
    }
    return mapped;
}


def _collect_asset_paths(files: list[ProjectFileEntry]) -> list[str] {
    assets: list[str] = [];
    for file_entry in files {
        if file_entry.kind != ProjectFileKind.ASSET {
            continue;
        }
        if file_entry.status == ProjectFileStatus.SKIP {
            assets.append(file_entry.source_path);
        }
    }
    assets.sort();
    return assets;
}


def _sorted_dep_map(raw: dict[str, any]) -> dict[str, str] {
    out: dict[str, str] = {};
    for (name, version) in sorted(raw.items()) {
        if not isinstance(name, str) or not name {
            continue;
        }
        if isinstance(version, str) and version.strip() {
            out[name] = version.strip();
        }
    }
    return out;
}


impl propose_project_config(
    project_root: str,
    files: list[ProjectFileEntry],
    diagnostics: list[Js2jacDiagnostic]
) -> (dict[str, any] | None) {
    convertible_by_source = {
        file_entry.source_path: file_entry
        for file_entry in files
        if file_entry.status == ProjectFileStatus.CONVERTIBLE
    };
    pkg_path = _find_config_file(project_root, ["package.json"]);
    tsconfig_path = _find_config_file(
        project_root, ["tsconfig.json", "tsconfig.app.json"]
    );
    pkg = _read_json_file(pkg_path) if pkg_path else {};
    if pkg is None {
        pkg = {};
    }
    tsconfig = _read_json_file(tsconfig_path) if tsconfig_path else {};
    if tsconfig is None {
        tsconfig = {};
    }
    deps = {};
    dev_deps = {};
    if isinstance(pkg.get("dependencies"), dict) {
        deps = _sorted_dep_map(pkg["dependencies"]);
    }
    if isinstance(pkg.get("devDependencies"), dict) {
        dev_deps = _sorted_dep_map(pkg["devDependencies"]);
    }
    framework = _detect_framework({**dev_deps, **deps});
    entry_jac = _detect_entry_jac(pkg, convertible_by_source);
    path_aliases = _extract_tsconfig_paths(tsconfig, diagnostics);
    assets = _collect_asset_paths(files);
    jac_toml: dict[str, any] = {
        "project": {
            "name": _package_name(pkg),
            "version": str(pkg.get("version", "0.1.0")),
            "description": str(pkg.get("description", "Converted with js2jac")),
            "entry-point": entry_jac or "main.jac"
        },
        "dependencies.npm": deps,
        "client": {
            "framework": framework,
            "target": "web"
        }
    };
    if dev_deps {
        jac_toml["dependencies.npm.dev"] = dev_deps;
    }
    if path_aliases {
        jac_toml["client.paths"] = path_aliases;
    }
    evidence: dict[str, str] = {};
    if pkg_path {
        evidence["packageJson"] = _normalize_rel_path(
            os.path.relpath(pkg_path, project_root)
        );
    }
    if tsconfig_path {
        evidence["tsconfigJson"] = _normalize_rel_path(
            os.path.relpath(tsconfig_path, project_root)
        );
    }
    proposal: dict[str, any] = {
        "assets": assets,
        "evidence": evidence,
        "jacToml": jac_toml
    };
    if path_aliases {
        proposal["pathAliases"] = path_aliases;
    }
    if entry_jac {
        proposal["entryPoint"] = entry_jac;
    }
    return proposal;
}


def _sha256_bytes(data: bytes) -> str {
    return f"sha256:{hashlib.sha256(data).hexdigest()}";
}


def _sha256_text(text: str) -> str {
    return _sha256_bytes(text.encode("utf-8"));
}


def _file_digest(abs_path: str) -> (str, bool) {
    if not os.path.isfile(abs_path) {
        return ("", False);
    }
    with open(abs_path, "rb") as in_f {
        data = in_f.read();
    }
    return (_sha256_bytes(data), True);
}


def _backup_root_for_manifest(manifest_path: str) -> str {
    manifest_dir = os.path.dirname(os.path.abspath(manifest_path));
    return os.path.join(manifest_dir, ".js2jac-backup");
}


def _format_toml_value(value: any) -> str {
    if isinstance(value, bool) {
        return "true" if value else "false";
    }
    if isinstance(value, (int, float)) {
        return str(value);
    }
    text = str(value);
    if text.isidentifier() {
        return f'"{text}"';
    }
    escaped = text.replace("\\", "\\\\").replace('"', '\\"');
    return f'"{escaped}"';
}


def _format_jac_toml_proposal(jac_toml: dict[str, any]) -> str {
    lines: list[str] = [];
    section_order = [
        "project",
        "dependencies.npm",
        "dependencies.npm.dev",
        "client",
        "client.paths"
    ];
    seen: set[str] = set();
    ordered = [s for s in section_order if s in jac_toml];
    for key in jac_toml.keys() {
        if key not in seen and key not in ordered {
            ordered.append(key);
        }
    }
    for section in ordered {
        payload = jac_toml.get(section);
        if not isinstance(payload, dict) or not payload {
            continue;
        }
        lines.append(f"[{section}]");
        for (name, value) in sorted(payload.items()) {
            lines.append(f"{name} = {_format_toml_value(value)}");
        }
        lines.append("");
    }
    return "\n".join(lines).rstrip() + "\n";
}


def _atomic_write_bytes(dest_path: str, data: bytes) -> None {
    parent = os.path.dirname(dest_path);
    if parent {
        os.makedirs(parent, exist_ok=True);
    }
    tmp_path = f"{dest_path}.js2jac-tmp";
    with open(tmp_path, "wb") as out_f {
        out_f.write(data);
    }
    os.replace(tmp_path, dest_path);
}


def _atomic_write_text(dest_path: str, text: str) -> None {
    _atomic_write_bytes(dest_path, text.encode("utf-8"));
}


def _collect_asset_entries(files: list[ProjectFileEntry]) -> list[ProjectFileEntry] {
    assets: list[ProjectFileEntry] = [];
    for entry in files {
        if entry.kind == ProjectFileKind.ASSET and entry.status == ProjectFileStatus.SKIP {
            assets.append(entry);
        }
    }
    assets.sort(key=lambda (item: ProjectFileEntry) { item.source_path; });
    return assets;
}


def _write_project_outputs(
    project_root: str,
    out_dir: str,
    emitted_files: dict[str, str],
    asset_entries: list[ProjectFileEntry],
    config_proposal: (dict[str, any] | None),
    rule_set_version: str,
    force: bool
) -> tuple[(RollbackManifest | None), list[Js2jacDiagnostic], list[str]] {
    import from jaclang.cli.cli { jac_version }

    diagnostics: list[Js2jacDiagnostic] = [];
    os.makedirs(out_dir, exist_ok=True);
    backup_root = os.path.join(out_dir, ".js2jac-backup");
    os.makedirs(backup_root, exist_ok=True);
    manifest = RollbackManifest(
        project_root=os.path.abspath(project_root),
        out_dir=os.path.abspath(out_dir),
        timestamp=datetime.datetime.now(datetime.timezone.utc).isoformat(),
        rule_set_version=rule_set_version,
        tool_version=jac_version()
    );
    copied_assets: list[str] = [];
    write_targets: list[tuple[str, bytes, str]] = [];
    for (rel_path, source) in sorted(emitted_files.items()) {
        write_targets.append((rel_path, source.encode("utf-8"), rel_path));
    }
    for asset_entry in asset_entries {
        src_abs = os.path.join(project_root, asset_entry.source_path);
        try {
            with open(src_abs, "rb") as in_f {
                data = in_f.read();
            }
        } except OSError as exc {
            diagnostics.append(
                Js2jacDiagnostic(
                    code="E7401",
                    message=f"Unable to read asset for copy: {exc}",
                    path=asset_entry.source_path,
                    category="project",
                    stage="write",
                    blocking=True
                )
            );
            return (None, diagnostics, []);
        }
        write_targets.append((asset_entry.source_path, data, asset_entry.source_path));
        copied_assets.append(asset_entry.source_path);
    }
    if config_proposal is not None {
        jac_toml = config_proposal.get("jacToml", {});
        if isinstance(jac_toml, dict) and jac_toml {
            proposal_text = _format_jac_toml_proposal(jac_toml);
            write_targets.append(
                ("jac.toml.proposed", proposal_text.encode("utf-8"), "jac.toml.proposed")
            );
        }
    }
    for (rel_path, data, original_path) in write_targets {
        dest_abs = os.path.join(out_dir, rel_path);
        (before_digest, existed) = _file_digest(dest_abs);
        if existed and not force {
            diagnostics.append(
                Js2jacDiagnostic(
                    code="E7413",
                    message=f"Refusing to overwrite existing output file: {rel_path}",
                    path=rel_path,
                    category="project",
                    stage="write",
                    blocking=True,
                    help="Pass --force to overwrite existing files in out-dir"
                )
            );
            return (None, diagnostics, []);
        }
        if existed and before_digest {
            backup_abs = os.path.join(backup_root, rel_path);
            backup_parent = os.path.dirname(backup_abs);
            if backup_parent {
                os.makedirs(backup_parent, exist_ok=True);
            }
            shutil.copy2(dest_abs, backup_abs);
        }
        _atomic_write_bytes(dest_abs, data);
        after_digest = _sha256_bytes(data);
        manifest.entries.append(
            RollbackEntry(
                original_path=original_path,
                new_path=rel_path,
                sha256_before=before_digest if existed else "",
                sha256_after=after_digest
            )
        );
    }
    manifest_path = os.path.join(out_dir, "rollback.json");
    _atomic_write_text(manifest_path, rollback_manifest_to_json(manifest));
    return (manifest, diagnostics, copied_assets);
}


def _restore_backup_file(
    out_dir: str,
    backup_root: str,
    rel_path: str
) -> bool {
    backup_abs = os.path.join(backup_root, rel_path);
    dest_abs = os.path.join(out_dir, rel_path);
    if not os.path.isfile(backup_abs) {
        return False;
    }
    parent = os.path.dirname(dest_abs);
    if parent {
        os.makedirs(parent, exist_ok=True);
    }
    shutil.copy2(backup_abs, dest_abs);
    return True;
}


def _reject_project_file(files: list[ProjectFileEntry], source_path: str) -> None {
    for entry in files {
        if entry.source_path == source_path {
            entry.status = ProjectFileStatus.REJECT;
            return;
        }
    }
}


def _degrade_plan_diagnostics(
    files: list[ProjectFileEntry],
    diagnostics: list[Js2jacDiagnostic]
) -> None {
    # In fail-open mode, a blocking diagnostic scoped to a single source file
    # (discover/graph stage rejects like E7401/E7405/E7406/E7409) degrades that
    # one file to a skip instead of aborting the whole project plan. Project-wide
    # diagnostics without a source path (case collisions, out-dir, symlink
    # escapes) stay blocking.
    source_paths = {entry.source_path for entry in files};
    for diag in diagnostics {
        if diag.blocking and diag.path and diag.path in source_paths {
            diag.blocking = False;
            _reject_project_file(files, diag.path);
        }
    }
}


def _record_file_failure(
    request: ProjectRequest,
    files: list[ProjectFileEntry],
    diagnostics: list[Js2jacDiagnostic],
    source_path: str,
    diag: Js2jacDiagnostic
) -> None {
    if request.fail_open {
        diag.blocking = False;
        _reject_project_file(files, source_path);
    }
    diagnostics.append(diag);
}


def _record_file_failure_many(
    request: ProjectRequest,
    files: list[ProjectFileEntry],
    diagnostics: list[Js2jacDiagnostic],
    source_path: str,
    diags: list[Js2jacDiagnostic]
) -> None {
    if request.fail_open {
        _reject_project_file(files, source_path);
        for d in diags {
            d.blocking = False;
        }
    }
    diagnostics.extend(diags);
}


def _collect_dependent_rejects(
    files: list[ProjectFileEntry],
    graph: ProjectGraphPlan
) -> set[str] {
    # Transitively find convertible files that import a rejected local module.
    # Emitting them would leave a dangling import to a file we skipped (jac check
    # only warns on the unresolved import, so staged validation misses it), so we
    # drop them too. Returns the newly-poisoned importers (excludes the already
    # rejected roots).
    rejected = {
        entry.source_path
        for entry in files
        if entry.status == ProjectFileStatus.REJECT
    };
    if not rejected {
        return set();
    }
    poisoned = set(rejected);
    changed = True;
    while changed {
        changed = False;
        for edge in graph.edges {
            frm = edge.get("from", "");
            to = edge.get("to", "");
            if to in poisoned and frm and frm not in poisoned {
                poisoned.add(frm);
                changed = True;
            }
        }
    }
    return poisoned - rejected;
}


def _validate_and_prune(
    emitted_files: dict[str, str],
    files: list[ProjectFileEntry],
    diagnostics: list[Js2jacDiagnostic]
) -> None {
    # Iteratively drop emitted files that fail the staged project check so a
    # single broken file (or one dangling on a dropped dependency) degrades to
    # a per-file skip instead of aborting the whole project.
    while emitted_files {
        stage_root = tempfile.mkdtemp(prefix="js2jac-project-");
        validate_diags: list[Js2jacDiagnostic] = [];
        try {
            _write_emitted_tree(stage_root, emitted_files);
            validate_diags = _validate_staged_project(
                stage_root, list(emitted_files.keys())
            );
        } finally {
            shutil.rmtree(stage_root, ignore_errors=True);
        }
        if not validate_diags {
            return;
        }
        failed_paths: set[str] = set();
        for d in validate_diags {
            d.blocking = False;
            diagnostics.append(d);
            if d.path {
                failed_paths.add(d.path);
            }
        }
        if not failed_paths {
            return;
        }
        for entry in files {
            if entry.jac_path in failed_paths {
                entry.status = ProjectFileStatus.REJECT;
            }
        }
        removed = False;
        for jac_path in failed_paths {
            if jac_path in emitted_files {
                emitted_files.pop(jac_path, None);
                removed = True;
            }
        }
        if not removed {
            return;
        }
    }
}


impl plan_project(request: ProjectRequest) -> ProjectResult {
    diagnostics: list[Js2jacDiagnostic] = [];
    project_root = request.project_root;
    if not project_root or not os.path.isdir(project_root) {
        return ProjectResult(
            ok=False,
            exit_code=1,
            diagnostics=[
                Js2jacDiagnostic(
                    code="E7401",
                    message="Project root is missing or not a directory",
                    category="project",
                    stage="discover",
                    blocking=True
                )
            ]
        );
    }
    project_root = os.path.abspath(project_root);
    out_dir = request.out_dir;
    if out_dir {
        out_dir = os.path.abspath(out_dir);
        out_diag = _validate_out_dir(project_root, out_dir);
        if out_diag is not None {
            diagnostics.append(out_diag);
            return ProjectResult(ok=False, diagnostics=diagnostics, exit_code=1);
        }
    }
    ignore_patterns = _collect_ignore_patterns(project_root);
    config = request.config;
    files = _discover_files(project_root, config, ignore_patterns, diagnostics);
    collision_diags = _detect_case_collisions(files);
    diagnostics.extend(collision_diags);
    convertible_paths = [
        f.source_path for f in files if f.status == ProjectFileStatus.CONVERTIBLE
    ];
    graph_scan_paths = [
        f.source_path
        for f in files
        if f.status in {
            ProjectFileStatus.CONVERTIBLE,
            ProjectFileStatus.INVENTORY
        }
        and f.kind == ProjectFileKind.SOURCE
    ];
    (graph_plan, graph_diags) = build_project_graph(
        project_root, graph_scan_paths
    );
    diagnostics.extend(graph_diags);
    type_alias_diags = scan_cross_file_props_types(
        project_root, convertible_paths, set(convertible_paths)
    );
    diagnostics.extend(type_alias_diags);
    if request.fail_open {
        _degrade_plan_diagnostics(files, diagnostics);
    }
    config_proposal = propose_project_config(project_root, files, diagnostics);
    blocking = any(d.blocking for d in diagnostics);
    plan = ProjectPlan(
        schema_version=PROJECT_PLAN_SCHEMA_VERSION,
        project_root=_normalize_rel_path(project_root),
        out_dir=_normalize_rel_path(out_dir) if out_dir else "",
        rule_set_version=request.rule_set_version or RULE_SET_VERSION,
        config_digest=_config_digest(config),
        files=files,
        graph=graph_plan,
        import_rewrites=[],
        diagnostics=diagnostics,
        config_proposal=config_proposal
    );
    return ProjectResult(
        ok=not blocking,
        plan=plan,
        diagnostics=diagnostics,
        exit_code=0 if not blocking else 1
    );
}


impl convert_project(request: ProjectRequest) -> ProjectResult {
    plan_result = plan_project(request);
    if not plan_result.ok {
        return plan_result;
    }
    if request.dry_run and not request.write {
        return plan_result;
    }
    if request.write and not request.out_dir {
        return ProjectResult(
            ok=False,
            plan=plan_result.plan,
            diagnostics=plan_result.diagnostics + [
                Js2jacDiagnostic(
                    code="E7401",
                    message="--write requires --out-dir",
                    category="project",
                    stage="write",
                    blocking=True
                )
            ],
            exit_code=1
        );
    }
    plan = plan_result.plan;
    diagnostics: list[Js2jacDiagnostic] = list(plan.diagnostics);
    project_root = os.path.abspath(request.project_root);
    convertible = [
        entry
        for entry in plan.files
        if entry.status == ProjectFileStatus.CONVERTIBLE
    ];
    if not convertible {
        return ProjectResult(
            ok=True,
            plan=plan,
            diagnostics=diagnostics,
            exit_code=0
        );
    }
    source_to_jac = {
        entry.source_path: entry.jac_path for entry in convertible if entry.jac_path
    };
    known_sources = set(source_to_jac.keys());
    conversion_order = scc_conversion_order(plan.graph);
    if not conversion_order {
        conversion_order = sorted(known_sources);
    }
    entry_by_source = {entry.source_path: entry for entry in convertible};
    virtual_path_map = build_virtual_path_map(source_to_jac);
    conv_config = default_config();
    conv_config.validation_level = ValidationLevel.FORMAT;
    conv_config.fail_open = request.fail_open;
    emitted_files: dict[str, str] = {};
    import_rewrites: list[dict[str, str]] = [];
    rewrite_seen: set[str] = set();
    # Public exports each module dropped in fail-open. Conversion runs in
    # dependency order (deps before importers), so by the time an importer is
    # converted its dependencies' dropped exports are final — a single forward
    # pass propagates the drop cross-file with no fixpoint.
    dropped_exports_by_source: dict[str, list[str]] = {};
    all_ok = True;
    for source_path in conversion_order {
        entry = entry_by_source.get(source_path);
        if entry is None {
            continue;
        }
        abs_path = os.path.join(project_root, entry.source_path);
        try {
            source_text = read_file_with_encoding(abs_path);
        } except OSError as exc {
            _record_file_failure(
                request,
                plan.files,
                diagnostics,
                entry.source_path,
                Js2jacDiagnostic(
                    code="E7401",
                    message=f"Unable to read source for conversion: {exc}",
                    path=entry.source_path,
                    category="project",
                    stage="convert",
                    blocking=True
                )
            );
            if not request.fail_open {
                all_ok = False;
            }
            continue;
        }
        language = language_from_suffix(entry.source_path);
        if language is None {
            _record_file_failure(
                request,
                plan.files,
                diagnostics,
                entry.source_path,
                Js2jacDiagnostic(
                    code="E7401",
                    message=f"Unsupported source language: {entry.source_path}",
                    path=entry.source_path,
                    category="project",
                    stage="convert",
                    blocking=True
                )
            );
            if not request.fail_open {
                all_ok = False;
            }
            continue;
        }
        conv_config.external_dropped = [];
        conv_result = convert(
            ConversionRequest(
                sources=[
                    SourceInput(
                        path=entry.source_path,
                        language=language,
                        source=source_text
                    )
                ],
                config=conv_config,
                virtual_path_map=virtual_path_map
            )
        );
        file_diags = list(conv_result.diagnostics) + list(
            conv_result.report.diagnostics
        );
        if not conv_result.ok {
            _record_file_failure_many(
                request, plan.files, diagnostics, entry.source_path, file_diags
            );
            if not request.fail_open {
                all_ok = False;
            }
            continue;
        }
        diagnostics.extend(file_diags);
        raw_jac = conv_result.emitted_files.get(entry.source_path, "");
        if not raw_jac.strip() {
            _record_file_failure(
                request,
                plan.files,
                diagnostics,
                entry.source_path,
                Js2jacDiagnostic(
                    code="E7206",
                    message="Conversion produced empty Jac output",
                    path=entry.source_path,
                    category="project",
                    stage="convert",
                    blocking=True
                )
            );
            if not request.fail_open {
                all_ok = False;
            }
            continue;
        }
        # Cross-file dropped-export propagation (fail-open): if this file imports
        # a public export a dependency dropped, re-convert it with those local
        # bindings marked dropped so the converter prunes the dead import and any
        # declaration using it — instead of leaving a dangling cross-file ref.
        if request.fail_open and dropped_exports_by_source {
            ext_dropped = collect_dropped_import_locals(
                entry.source_path,
                raw_jac,
                known_sources,
                dropped_exports_by_source
            );
            if ext_dropped {
                conv_config.external_dropped = ext_dropped;
                conv_result = convert(
                    ConversionRequest(
                        sources=[
                            SourceInput(
                                path=entry.source_path,
                                language=language,
                                source=source_text
                            )
                        ],
                        config=conv_config,
                        virtual_path_map=virtual_path_map
                    )
                );
                conv_config.external_dropped = [];
                extra_diags = list(conv_result.diagnostics) + list(
                    conv_result.report.diagnostics
                );
                if not conv_result.ok {
                    # Every convertible declaration depended on a dropped upstream
                    # export — drop this file too (sound: no dangling reference).
                    _record_file_failure_many(
                        request,
                        plan.files,
                        diagnostics,
                        entry.source_path,
                        extra_diags
                    );
                    continue;
                }
                diagnostics.extend(extra_diags);
                raw_jac = conv_result.emitted_files.get(entry.source_path, "");
            }
        }
        if request.fail_open {
            dropped_exports_by_source[entry.source_path] = list(
                conv_result.dropped_exports
            );
        }
        (rewritten_jac, file_rewrites) = build_import_rewrites(
            entry.source_path,
            entry.jac_path,
            raw_jac,
            source_to_jac,
            known_sources,
            plan.graph.default_export_names,
            plan.graph.reexport_bindings,
            plan.graph.star_reexports,
            plan.graph.module_exports
        );
        for rewrite in file_rewrites {
            key = (
                f"{rewrite.get('sourcePath', '')}|"
                f"{rewrite.get('fromModule', '')}|"
                f"{rewrite.get('toModule', '')}"
            );
            if key in rewrite_seen {
                continue;
            }
            rewrite_seen.add(key);
            import_rewrites.append(rewrite);
        }
        emitted_files[entry.jac_path] = rewritten_jac;
    }
    import_rewrites.sort(
        key=lambda (item: dict[str, str]) {
            (
                item.get("sourcePath", ""),
                item.get("fromModule", ""),
                item.get("toModule", "")
            );
        }
    );
    plan.import_rewrites = import_rewrites;
    if request.fail_open {
        dependent_rejects = _collect_dependent_rejects(plan.files, plan.graph);
        for entry in plan.files {
            if entry.source_path in dependent_rejects {
                entry.status = ProjectFileStatus.REJECT;
                if entry.jac_path in emitted_files {
                    emitted_files.pop(entry.jac_path, None);
                }
                diagnostics.append(
                    Js2jacDiagnostic(
                        code="E7407",
                        message=(
                            f"Skipped: imports a module skipped in fail-open mode: "
                            f"{entry.source_path}"
                        ),
                        path=entry.source_path,
                        category="project",
                        stage="convert",
                        blocking=False,
                        help="A local module this file imports could not be converted"
                    )
                );
            }
        }
        if emitted_files {
            _validate_and_prune(emitted_files, plan.files, diagnostics);
        }
    } elif all_ok and emitted_files {
        stage_root = tempfile.mkdtemp(prefix="js2jac-project-");
        try {
            _write_emitted_tree(stage_root, emitted_files);
            validate_diags = _validate_staged_project(
                stage_root, list(emitted_files.keys())
            );
            diagnostics.extend(validate_diags);
            if validate_diags {
                all_ok = False;
            }
        } finally {
            shutil.rmtree(stage_root, ignore_errors=True);
        }
    }
    blocking = any(d.blocking for d in diagnostics);
    all_ok = all_ok and not blocking;
    copied_assets: list[str] = [];
    rollback_manifest_path = "";
    if request.write and all_ok and request.out_dir {
        asset_entries = _collect_asset_entries(plan.files);
        (manifest, write_diags, copied_assets) = _write_project_outputs(
            project_root,
            os.path.abspath(request.out_dir),
            emitted_files,
            asset_entries,
            plan.config_proposal,
            plan.rule_set_version,
            request.force
        );
        diagnostics.extend(write_diags);
        if write_diags {
            all_ok = False;
        } elif manifest is not None {
            rollback_manifest_path = os.path.join(
                os.path.abspath(request.out_dir), "rollback.json"
            );
        }
    }
    return ProjectResult(
        ok=all_ok,
        plan=plan,
        emitted_files=emitted_files,
        copied_assets=copied_assets,
        rollback_manifest_path=rollback_manifest_path,
        diagnostics=diagnostics,
        exit_code=0 if all_ok else 1
    );
}


def _file_entry_to_dict(file_entry: ProjectFileEntry) -> dict[str, any] {
    out: dict[str, any] = {
        "bytes": file_entry.byte_size,
        "kind": file_entry.kind.value,
        "sha256": file_entry.sha256,
        "sourcePath": file_entry.source_path,
        "status": file_entry.status.value
    };
    if file_entry.jac_path {
        out["jacPath"] = file_entry.jac_path;
    }
    if file_entry.language {
        out["language"] = file_entry.language;
    }
    return out;
}


impl project_plan_to_json(plan: ProjectPlan) -> str {
    payload: dict[str, any] = {
        "configDigest": plan.config_digest,
        "diagnostics": [
            {
                "blocking": d.blocking,
                "category": d.category,
                "code": d.code,
                "details": d.details,
                "help": d.help,
                "message": d.message,
                "severity": d.severity,
                "stage": d.stage,
                "source": {"path": d.path} if d.path else {}
            }
            for d in plan.diagnostics
        ],
        "files": [_file_entry_to_dict(f) for f in plan.files],
        "graph": {
            "edges": plan.graph.edges,
            "nodes": plan.graph.nodes,
            "sccs": plan.graph.sccs
        },
        "importRewrites": plan.import_rewrites,
        "outDir": plan.out_dir,
        "projectRoot": plan.project_root,
        "ruleSetVersion": plan.rule_set_version,
        "schemaVersion": plan.schema_version
    };
    if plan.config_proposal is not None {
        payload["configProposal"] = plan.config_proposal;
    }
    return json.dumps(payload, sort_keys=True, indent=2);
}


def _rollback_entry_to_dict(rollback_entry: RollbackEntry) -> dict[str, str] {
    return {
        "newPath": rollback_entry.new_path,
        "originalPath": rollback_entry.original_path,
        "sha256After": rollback_entry.sha256_after,
        "sha256Before": rollback_entry.sha256_before
    };
}


def _rollback_entry_from_dict(raw: dict[str, any]) -> RollbackEntry {
    return RollbackEntry(
        original_path=str(raw.get("originalPath", "")),
        new_path=str(raw.get("newPath", "")),
        sha256_before=str(raw.get("sha256Before", "")),
        sha256_after=str(raw.get("sha256After", ""))
    );
}


impl rollback_manifest_to_json(manifest: RollbackManifest) -> str {
    payload: dict[str, any] = {
        "entries": [_rollback_entry_to_dict(e) for e in manifest.entries],
        "outDir": manifest.out_dir,
        "projectRoot": manifest.project_root,
        "ruleSetVersion": manifest.rule_set_version,
        "timestamp": manifest.timestamp,
        "toolVersion": manifest.tool_version
    };
    return json.dumps(payload, sort_keys=True, indent=2);
}


def _rollback_manifest_from_json(text: str) -> (RollbackManifest | None) {
    try {
        raw = json.loads(text);
    } except json.JSONDecodeError {
        return None;
    }
    if not isinstance(raw, dict) {
        return None;
    }
    entries: list[RollbackEntry] = [];
    raw_entries = raw.get("entries", []);
    if isinstance(raw_entries, list) {
        for item in raw_entries {
            if isinstance(item, dict) {
                entries.append(_rollback_entry_from_dict(item));
            }
        }
    }
    return RollbackManifest(
        project_root=str(raw.get("projectRoot", "")),
        out_dir=str(raw.get("outDir", "")),
        timestamp=str(raw.get("timestamp", "")),
        rule_set_version=str(raw.get("ruleSetVersion", "")),
        tool_version=str(raw.get("toolVersion", "")),
        entries=entries
    );
}


impl rollback_project(manifest_path: str) -> ProjectResult {
    diagnostics: list[Js2jacDiagnostic] = [];
    if not manifest_path or not os.path.isfile(manifest_path) {
        return ProjectResult(
            ok=False,
            exit_code=1,
            diagnostics=[
                Js2jacDiagnostic(
                    code="E7401",
                    message="Rollback manifest is missing or not a file",
                    category="project",
                    stage="rollback",
                    blocking=True
                )
            ]
        );
    }
    try {
        with open(manifest_path, "r", encoding="utf-8") as in_f {
            text = in_f.read();
        }
    } except OSError as exc {
        return ProjectResult(
            ok=False,
            exit_code=1,
            diagnostics=[
                Js2jacDiagnostic(
                    code="E7401",
                    message=f"Unable to read rollback manifest: {exc}",
                    category="project",
                    stage="rollback",
                    blocking=True
                )
            ]
        );
    }
    manifest = _rollback_manifest_from_json(text);
    if manifest is None {
        return ProjectResult(
            ok=False,
            exit_code=1,
            diagnostics=[
                Js2jacDiagnostic(
                    code="E7401",
                    message="Rollback manifest is not valid JSON",
                    category="project",
                    stage="rollback",
                    blocking=True
                )
            ]
        );
    }
    out_dir = manifest.out_dir;
    manifest_dir = os.path.dirname(os.path.abspath(manifest_path));
    if not out_dir {
        out_dir = manifest_dir;
    } elif not os.path.isabs(out_dir) {
        out_dir = manifest_dir;
    } else {
        out_dir = os.path.abspath(out_dir);
    }
    backup_root = _backup_root_for_manifest(manifest_path);
    conflicts: list[str] = [];
    for entry in manifest.entries {
        dest_abs = os.path.join(out_dir, entry.new_path);
        (current_digest, existed) = _file_digest(dest_abs);
        if not existed {
            if entry.sha256_after {
                conflicts.append(entry.new_path);
            }
            continue;
        }
        if current_digest != entry.sha256_after {
            conflicts.append(entry.new_path);
        }
    }
    if conflicts {
        for rel_path in sorted(conflicts) {
            diagnostics.append(
                Js2jacDiagnostic(
                    code="E7408",
                    message=(
                        f"Rollback conflict: {rel_path} changed since conversion write"
                    ),
                    path=rel_path,
                    category="project",
                    stage="rollback",
                    blocking=True,
                    help="Restore or remove changed files manually before rollback"
                )
            );
        }
        return ProjectResult(ok=False, diagnostics=diagnostics, exit_code=1);
    }
    for entry in manifest.entries {
        dest_abs = os.path.join(out_dir, entry.new_path);
        if entry.sha256_before {
            if not _restore_backup_file(out_dir, backup_root, entry.new_path) {
                diagnostics.append(
                    Js2jacDiagnostic(
                        code="E7401",
                        message=(
                            f"Missing backup for rollback restore: {entry.new_path}"
                        ),
                        path=entry.new_path,
                        category="project",
                        stage="rollback",
                        blocking=True
                    )
                );
                return ProjectResult(ok=False, diagnostics=diagnostics, exit_code=1);
            }
        } elif os.path.isfile(dest_abs) {
            os.remove(dest_abs);
        }
    }
    if os.path.isfile(manifest_path) {
        os.remove(manifest_path);
    }
    return ProjectResult(ok=True, diagnostics=diagnostics, exit_code=0);
}
