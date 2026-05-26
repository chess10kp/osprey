#!/usr/bin/env python3
"""JSON stdio bridge — invoked by src/jac/jac-bridge.ts to run lib/jac/jac toolchain code."""

from __future__ import annotations

import json
import os
import sys
import traceback

_LIB_JAC_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
for _subdir in (
    "jac",
    "config",
    "project",
    "workflow",
    "orchestration",
    "agent",
    "ui",
    "render",
):
    _pkg = os.path.join(_LIB_JAC_ROOT, _subdir)
    if os.path.isdir(_pkg) and _pkg not in sys.path:
        sys.path.insert(0, _pkg)

from _cli_toolchain import (  # noqa: E402
    find_jac_binary,
    fingerprint_errors,
    format_diagnostics,
    parse_jac_check_output,
    run_jac_check,
    run_jac_command,
    run_jac_format,
    run_jac_run_file,
    run_jac_test,
)
from _doctor_toolchain import run_jac_doctor  # noqa: E402
from _lsp_toolchain import resolve_lsp_config  # noqa: E402
from _file_explorer_toolchain import (  # noqa: E402
    list_project_files,
    estimate_selection_chars,
)
from _workflows_toolchain import (  # noqa: E402
    build_convert_python_prompt,
    build_diagram_to_model_prompt,
    build_explain_prompt,
    build_idiom_review_prompt,
    build_osp_prompt,
    load_skill_content,
    render_prompt_template,
    resolve_package_root,
)
from _project_config_toolchain import (  # noqa: E402
    find_config_path as _find_config_path,
    load_project_config as _load_project_config,
    resolve_default_mode as _resolve_default_mode,
)


def _dispatch(req: dict) -> dict:
    op = req.get("op")
    if not op:
        raise ValueError("missing op")

    if op == "find_binary":
        found = find_jac_binary()
        return {"binary": found or None}

    if op == "parse_check":
        return {
            "diagnostics": parse_jac_check_output(
                req.get("stdout", ""), req.get("stderr", "")
            )
        }

    if op == "fingerprint":
        return {"fingerprint": fingerprint_errors(req.get("errors", []))}

    if op == "format_diagnostics":
        return {"formatted": format_diagnostics(req.get("diagnostics", []))}

    if op == "run_command":
        result = run_jac_command(
            req["cmd"],
            req["cwd"],
            timeout_ms=req.get("timeoutMs", 120000),
            parse_diagnostics=req.get("parseDiagnostics", True),
        )
        return {"result": result}

    if op == "run_check":
        return {"result": run_jac_check(req["cwd"], req.get("files"))}

    if op == "run_format":
        return {"result": run_jac_format(req["cwd"], req.get("files", []))}

    if op == "run_test":
        return {"result": run_jac_test(req["cwd"], req.get("files"))}

    if op == "run_run":
        return {
            "result": run_jac_run_file(
                req["cwd"],
                req["file"],
                req.get("args"),
                req.get("timeoutMs", 60000),
            )
        }

    if op == "doctor":
        return {"result": run_jac_doctor(req["cwd"])}

    if op == "resolve_lsp_config":
        return {
            "result": resolve_lsp_config(
                req["cwd"], req.get("projectConfig") or {}
            )
        }

    if op == "project_list_files":
        return {
            "result": list_project_files(
                req["cwd"],
                max_depth=req.get("maxDepth", 6),
                max_files=req.get("maxFiles", 3000),
                respect_gitignore=req.get("respectGitignore", True),
            )
        }

    if op == "project_estimate_selection":
        return {
            "result": estimate_selection_chars(
                req["cwd"],
                req.get("paths", []),
            )
        }

    # --- config ops (Phase 2A.1) ---

    if op == "project_load_config":
        return {"result": _load_project_config(req["cwd"])}

    if op == "project_find_config_path":
        return {"result": _find_config_path(req["cwd"])}

    if op == "project_resolve_default_mode":
        return {"result": _resolve_default_mode(req.get("config", {}))}

    root = req.get("packageRoot")

    if op == "workflows_package_root":
        return {"result": resolve_package_root(root)}

    if op == "workflows_load_skill":
        return {"result": load_skill_content(req["skillDir"], root)}

    if op == "workflows_render_prompt":
        return {
            "result": render_prompt_template(req["name"], req.get("vars", {}), root)
        }

    if op == "workflows_build_osp":
        return {"result": build_osp_prompt(req["description"], root)}

    if op == "workflows_build_convert_python":
        return {"result": build_convert_python_prompt(req["path"], root)}

    if op == "workflows_build_idiom_review":
        return {"result": build_idiom_review_prompt(req.get("paths", []), root)}

    if op == "workflows_build_explain":
        return {
            "result": build_explain_prompt(req["mode"], req.get("args", ""), root)
        }

    if op == "workflows_build_diagram":
        return {
            "result": build_diagram_to_model_prompt(
                req.get("source", ""), req.get("content", ""), root
            )
        }

    raise ValueError(f"unknown op: {op}")


def main() -> int:
    raw = sys.stdin.read()
    if not raw.strip():
        print(json.dumps({"ok": False, "error": "empty request"}))
        return 1
    try:
        req = json.loads(raw)
        payload = _dispatch(req)
        print(json.dumps({"ok": True, **payload}))
        return 0
    except Exception as e:
        print(
            json.dumps(
                {
                    "ok": False,
                    "error": str(e),
                    "trace": traceback.format_exc(),
                }
            )
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
