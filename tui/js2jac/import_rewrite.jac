"""Local import path rewriting for js2jac project mode (P4.3)."""

import from jaclang.compiler.js2jac.graph { resolve_local_specifier }


def jac_relative_import(from_jac_path: str, to_jac_path: str) -> str;

def build_import_rewrites(
    source_path: str,
    jac_path: str,
    jac_source: str,
    source_to_jac: dict[str, str],
    known_sources: set[str],
    default_names: dict[str, str] = {},
    reexport_bindings: list[dict[str, str]] = [],
    star_reexports: dict[str, list[str]] = {},
    module_exports: dict[str, list[str]] = {}
) -> tuple[str, list[dict[str, str]]];

def build_virtual_path_map(source_to_jac: dict[str, str]) -> dict[str, str];


def collect_dropped_import_locals(
    source_path: str,
    jac_source: str,
    known_sources: set[str],
    dropped_exports_by_source: dict[str, list[str]]
) -> list[str];
