"""Static import/export graph for js2jac project mode (P4.2)."""

import from jaclang.compiler.js2jac.model { Js2jacDiagnostic }


enum ModuleEdgeKind {
    IMPORT = "import",
    REEXPORT = "reexport",
    STAR_REEXPORT = "star_reexport"
}

obj ProjectGraphPlan {
    has nodes: list[str] = [],
        edges: list[dict[str, str]] = [],
        sccs: list[list[str]] = [],
        default_export_names: dict[str, str] = {},
        # Named re-export bindings from pure barrels (re-export-only modules).
        # Each record: {"barrel": <src>, "export": <public name>,
        # "local": <name in target>, "target": <target src>}. Used to bypass
        # barrels (never emitted) so importers point straight at real modules.
        reexport_bindings: list[dict[str, str]] = [],
        # Star re-exports (`export * from './t'`): barrel source -> list of
        # target sources. Carries no static names, so importers through a
        # star-barrel resolve each name against the targets' `module_exports`.
        star_reexports: dict[str, list[str]] = {},
        # Named (non-default) exports per module, used to disambiguate which
        # star-target actually provides a name during a star-barrel bypass.
        module_exports: dict[str, list[str]] = {};
}

obj ModuleSurfaceScan {
    has source_path: str = "",
        specifiers: list[dict[str, any]] = [],
        export_names: list[str] = [],
        star_export_count: int = 0,
        default_export_name: str = "",
        diagnostics: list[Js2jacDiagnostic] = [];
}


def scan_module_surface(source_path: str, source: str) -> ModuleSurfaceScan;

def is_reexport_only_module(source: str) -> bool;

def resolve_local_specifier(
    specifier: str,
    from_path: str,
    known_sources: set[str]
) -> (str | None);

def build_project_graph(
    project_root: str,
    convertible_paths: list[str]
) -> tuple[ProjectGraphPlan, list[Js2jacDiagnostic]];

def scc_conversion_order(plan: ProjectGraphPlan) -> list[str];

def scan_cross_file_props_types(
    project_root: str,
    convertible_paths: list[str],
    known_sources: set[str]
) -> list[Js2jacDiagnostic];
