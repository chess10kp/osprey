"""Project-mode discovery and dry-run planning for js2jac (P4.1+)."""

import from jaclang.compiler.js2jac.graph { ProjectGraphPlan }
import from jaclang.compiler.js2jac.model { Js2jacDiagnostic, RULE_SET_VERSION }


glob PROJECT_PLAN_SCHEMA_VERSION: int = 1;

enum ProjectFileStatus {
    CONVERTIBLE = "convertible",
    SKIP = "skip",
    REJECT = "reject",
    INVENTORY = "inventory"
}

enum ProjectFileKind {
    SOURCE = "source",
    DECLARATION = "declaration",
    ASSET = "asset",
    CONFIG = "config",
    GENERATED = "generated",
    VENDOR = "vendor"
}

obj ProjectDiscoveryConfig {
    has include: list[str] = [
            "**/*.{js,jsx,ts,tsx}"
        ],
        exclude: list[str] = [
            "**/node_modules/**",
            "**/dist/**",
            "**/.next/**",
            "**/build/**",
            "**/*.d.ts"
        ],
        max_file_bytes: int = 1_048_576;
}

obj ProjectRequest {
    has project_root: str = "",
        out_dir: str = "",
        dry_run: bool = True,
        write: bool = False,
        force: bool = False,
        fail_open: bool = False,
        config: ProjectDiscoveryConfig = ProjectDiscoveryConfig(),
        rule_set_version: str = RULE_SET_VERSION;
}

obj RollbackEntry {
    has original_path: str = "",
        new_path: str = "",
        sha256_before: str = "",
        sha256_after: str = "";
}

obj RollbackManifest {
    has project_root: str = "",
        out_dir: str = "",
        timestamp: str = "",
        rule_set_version: str = "",
        tool_version: str = "",
        entries: list[RollbackEntry] = [];
}

obj ProjectFileEntry {
    has source_path: str = "",
        jac_path: str = "",
        language: str = "",
        sha256: str = "",
        status: ProjectFileStatus = ProjectFileStatus.SKIP,
        kind: ProjectFileKind = ProjectFileKind.SOURCE,
        byte_size: int = 0;
}

obj ProjectPlan {
    has schema_version: int = PROJECT_PLAN_SCHEMA_VERSION,
        project_root: str = "",
        out_dir: str = "",
        rule_set_version: str = "",
        config_digest: str = "",
        files: list[ProjectFileEntry] = [],
        graph: ProjectGraphPlan = ProjectGraphPlan(),
        import_rewrites: list[dict[str, str]] = [],
        diagnostics: list[Js2jacDiagnostic] = [],
        config_proposal: (dict[str, any] | None) = None;
}

obj ProjectResult {
    has ok: bool = False,
        plan: ProjectPlan = ProjectPlan(),
        emitted_files: dict[str, str] = {},
        copied_assets: list[str] = [],
        rollback_manifest_path: str = "",
        diagnostics: list[Js2jacDiagnostic] = [],
        exit_code: int = 1;
}


def plan_project(request: ProjectRequest) -> ProjectResult;

def convert_project(request: ProjectRequest) -> ProjectResult;

def rollback_project(manifest_path: str) -> ProjectResult;

def project_plan_to_json(plan: ProjectPlan) -> str;

def rollback_manifest_to_json(manifest: RollbackManifest) -> str;

def propose_project_config(
    project_root: str,
    files: list[ProjectFileEntry],
    diagnostics: list[Js2jacDiagnostic]
) -> (dict[str, any] | None);
