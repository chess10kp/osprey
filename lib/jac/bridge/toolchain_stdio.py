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
from _frontmatter_toolchain import (  # noqa: E402
    parse_frontmatter as _parse_frontmatter,
    frontmatter_string as _frontmatter_string,
    frontmatter_string_list as _frontmatter_string_list,
)
from _file_mention_parser_toolchain import (  # noqa: E402
    parse_file_mentions as _parse_file_mentions,
    parse_line_range as _parse_line_range,
    is_valid_file_path as _is_valid_file_path,
    parse_mention_token as _parse_mention_token,
    get_current_file_mention as _get_current_file_mention,
)
from _context_usage_toolchain import (  # noqa: E402
    estimate_tokens as _estimate_tokens,
    estimate_messages_tokens as _estimate_messages_tokens,
    get_context_max as _get_context_max,
    compute_context_usage as _compute_context_usage,
    format_usage_line as _format_usage_line,
)
from _tasks_toolchain import (  # noqa: E402
    load_tasks as _load_tasks,
    save_tasks as _save_tasks,
    clear_tasks as _clear_tasks,
    add_task as _add_task,
    remove_task_by_index as _remove_task_by_index,
    remove_task_by_id as _remove_task_by_id,
    update_tasks as _update_tasks,
    task_counts as _task_counts,
    format_task_line as _format_task_line,
    format_tasks_list as _format_tasks_list,
    tasks_path as _tasks_path,
    generate_task_id as _generate_task_id,
)
from _custom_commands_toolchain import (  # noqa: E402
    load_custom_commands as _load_custom_commands,
    expand_command_template as _expand_command_template,
    resolve_custom_command_input as _resolve_custom_command_input,
    expand_custom_command as _expand_custom_command,
    try_expand_slash_command as _try_expand_slash_command,
    format_custom_command_catalog as _format_custom_command_catalog,
    custom_command_slash_names as _custom_command_slash_names,
)
from _dev_mode_toolchain import (  # noqa: E402
    is_read_only_mode as _is_read_only_mode,
    is_tool_blocked_in_read_only_mode as _is_tool_blocked_in_read_only_mode,
    cycle_mode as _cycle_mode,
    parse_mode_flag as _parse_mode_flag,
    system_prompt_for_mode as _system_prompt_for_mode,
    is_destructive_bash as _is_destructive_bash,
    should_auto_approve as _should_auto_approve,
    read_only_mode_block_reason as _read_only_mode_block_reason,
    READ_ONLY_MODE_BLOCKED_TOOLS as _READ_ONLY_MODE_BLOCKED_TOOLS,
)
from _system_prompt_toolchain import load_system_prompt_base as _load_system_prompt_base  # noqa: E402
from _tool_output_limit_toolchain import (  # noqa: E402
    MAX_TOOL_OUTPUT_BYTES as _MAX_TOOL_OUTPUT_BYTES,
    truncate_tool_output as _truncate_tool_output,
    truncate_tool_payload as _truncate_tool_payload,
)
from _skill_commands_toolchain import (  # noqa: E402
    format_skill_command_catalog as _format_skill_command_catalog,
)
from _session_permissions_toolchain import (  # noqa: E402
    match_pattern as _match_pattern,
    evaluate_permission_patterns as _evaluate_permission_patterns,
    load_always_allow_tools as _load_always_allow_tools,
    load_permission_patterns as _load_permission_patterns,
    needs_tool_approval as _needs_tool_approval,
)
from _context_input_toolchain import (  # noqa: E402
    load_file_slice as _load_file_slice,
    run_inline_command as _run_inline_command,
    expand_context_input_sync as _expand_context_input_sync,
)
from _approval_display_toolchain import format_approval_display as _format_approval_display  # noqa: E402
from _completions_toolchain import get_suggestions as _get_suggestions  # noqa: E402
from _overlay_rows_toolchain import (  # noqa: E402
    task_status_icon as _task_status_icon,
    format_task_overlay_row as _format_task_overlay_row,
    format_tasks_overlay_header as _format_tasks_overlay_header,
)
from _checkpoints_toolchain import (  # noqa: E402
    checkpoints_dir as _checkpoints_dir,
    validate_checkpoint_name as _validate_checkpoint_name,
    get_modified_files as _get_modified_files,
    create_checkpoint as _create_checkpoint,
    load_checkpoint as _load_checkpoint,
    list_checkpoints as _list_checkpoints,
    delete_checkpoint as _delete_checkpoint,
    restore_checkpoint_files as _restore_checkpoint_files,
    format_relative_time as _format_relative_time,
    format_checkpoint_overlay_row as _format_checkpoint_overlay_row,
    format_checkpoint_list as _format_checkpoint_list,
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

    # --- frontmatter ops ---

    if op == "frontmatter_parse":
        result = _parse_frontmatter(req.get("content", ""))
        return {"result": {"frontmatter": result.frontmatter, "body": result.body}}

    if op == "frontmatter_string":
        return {"result": _frontmatter_string(req.get("value"))}

    if op == "frontmatter_string_list":
        return {"result": _frontmatter_string_list(req.get("value"))}

    # --- file mention parser ops ---

    if op == "parse_file_mentions":
        mentions = _parse_file_mentions(req.get("input", ""))
        return {"result": [
            {
                "rawText": m.raw_text,
                "filePath": m.file_path,
                "startIndex": m.start_index,
                "endIndex": m.end_index,
                "lineRange": m.line_range,
            }
            for m in mentions
        ]}

    if op == "parse_line_range":
        return {"result": _parse_line_range(req.get("rangeStr", ""))}

    if op == "is_valid_file_path":
        return {"result": _is_valid_file_path(req.get("filePath", ""))}

    if op == "parse_mention_token":
        return {"result": _parse_mention_token(req.get("raw", ""))}

    if op == "get_current_file_mention":
        return {"result": _get_current_file_mention(
            req.get("input", ""), req.get("cursorPosition"),
        )}

    # --- context usage ops ---

    if op == "estimate_tokens":
        return {"result": _estimate_tokens(req.get("text", ""))}

    if op == "estimate_messages_tokens":
        return {"result": _estimate_messages_tokens(req.get("messages", []))}

    if op == "get_context_max":
        return {"result": _get_context_max(
            req.get("contextWindow"), req.get("override"),
        )}

    if op == "compute_context_usage":
        return {"result": _compute_context_usage(
            req.get("messages", []),
            req.get("systemPrompt", ""),
            req.get("contextWindow"),
            req.get("contextMaxOverride"),
        )}

    if op == "format_usage_line":
        return {"result": _format_usage_line(req.get("usage", {}))}

    # --- tasks ops ---

    if op == "tasks_load":
        return {"result": _load_tasks(req["cwd"])}

    if op == "tasks_save":
        _save_tasks(req["cwd"], req.get("tasks", []))
        return {"result": True}

    if op == "tasks_clear":
        _clear_tasks(req["cwd"])
        return {"result": True}

    if op == "tasks_add":
        return {"result": _add_task(req["cwd"], req["title"], req.get("description"))}

    if op == "tasks_remove_by_index":
        return {"result": _remove_task_by_index(req["cwd"], req["index"])}

    if op == "tasks_remove_by_id":
        return {"result": _remove_task_by_id(req["cwd"], req["id"])}

    if op == "tasks_update":
        return {"result": _update_tasks(req["cwd"], req.get("updates", []))}

    if op == "tasks_counts":
        return {"result": _task_counts(req.get("tasks", []))}

    if op == "tasks_format_line":
        return {"result": _format_task_line(req.get("task", {}))}

    if op == "tasks_format_list":
        return {"result": _format_tasks_list(
            req.get("tasks", []), req.get("title", "Tasks"),
        )}

    if op == "tasks_path":
        return {"result": _tasks_path(req["cwd"])}

    if op == "tasks_generate_id":
        return {"result": _generate_task_id()}

    # --- custom commands ops ---

    if op == "custom_commands_load":
        return {"result": _load_custom_commands(req["cwd"])}

    if op == "custom_commands_expand_template":
        return {"result": _expand_command_template(
            req["template"], req.get("command", ""),
            req.get("args", []), req.get("parameters", []), req.get("cwd", ""),
        )}

    if op == "custom_commands_resolve_input":
        return {"result": _resolve_custom_command_input(
            req.get("input", ""), req.get("commands", []),
        )}

    if op == "custom_commands_expand":
        return {"result": _expand_custom_command(
            req["command"], req.get("args", []), req.get("cwd", ""),
        )}

    if op == "custom_commands_try_expand":
        return {"result": _try_expand_slash_command(
            req.get("text", ""), req["cwd"],
        )}

    if op == "custom_commands_catalog":
        return {"result": _format_custom_command_catalog(req["cwd"])}

    if op == "custom_commands_slash_names":
        return {"result": _custom_command_slash_names(req["cwd"])}

    # --- dev mode ops ---

    if op == "dev_mode_is_read_only":
        return {"result": _is_read_only_mode(req.get("mode", ""))}

    if op == "dev_mode_is_tool_blocked":
        return {"result": _is_tool_blocked_in_read_only_mode(req.get("toolName", ""))}

    if op == "dev_mode_cycle":
        return {"result": _cycle_mode(req.get("current", "normal"))}

    if op == "dev_mode_parse_flag":
        return {"result": _parse_mode_flag(req.get("args", []))}

    if op == "dev_mode_system_prompt":
        return {"result": _system_prompt_for_mode(
            req.get("basePrompt", ""), req.get("mode", "normal"),
        )}

    if op == "dev_mode_is_destructive_bash":
        return {"result": _is_destructive_bash(req.get("cmd", ""))}

    if op == "dev_mode_should_auto_approve":
        return {"result": _should_auto_approve(
            req.get("mode", "normal"), req.get("toolName", ""), req.get("params", {}),
        )}

    if op == "dev_mode_block_reason":
        return {"result": _read_only_mode_block_reason(
            req.get("toolName", ""), req.get("mode", "plan"),
        )}

    if op == "dev_mode_blocked_tools":
        return {"result": sorted(_READ_ONLY_MODE_BLOCKED_TOOLS)}

    # --- system prompt / skill commands / output limit ops ---

    if op == "agent_load_system_prompt_base":
        return {"result": _load_system_prompt_base(req["cwd"], req.get("explicit"))}

    if op == "workflow_format_skill_command_catalog":
        return {"result": _format_skill_command_catalog(req.get("skills", []))}

    if op == "tool_output_max_bytes":
        return {"result": _MAX_TOOL_OUTPUT_BYTES}

    if op == "tool_output_truncate":
        return {"result": _truncate_tool_output(req.get("text", ""), req.get("maxBytes", _MAX_TOOL_OUTPUT_BYTES))}

    if op == "tool_output_truncate_payload":
        return {"result": _truncate_tool_payload(req.get("value"))}

    # --- session permissions ops ---

    if op == "permissions_match_pattern":
        return {"result": _match_pattern(req.get("resource", ""), req.get("pattern", ""), req.get("type", "glob"))}

    if op == "permissions_evaluate":
        return {"result": _evaluate_permission_patterns(req.get("patterns", []), req.get("toolName", ""), req.get("resource", ""))}

    if op == "permissions_load_always_allow":
        return {"result": _load_always_allow_tools(req["cwd"], req.get("projectConfig"))}

    if op == "permissions_load_patterns":
        return {"result": _load_permission_patterns(req.get("projectConfig"))}

    if op == "permissions_needs_approval":
        return {"result": _needs_tool_approval(
            req["mode"], req["toolName"], req.get("params", {}),
            session_granted=req.get("sessionGranted"),
            session_pattern_grants=req.get("sessionPatternGrants"),
            always_allow=req.get("alwaysAllow"),
            permission_patterns=req.get("permissionPatterns"),
            resource=req.get("resource"),
        )}

    # --- context input ops ---

    if op == "context_expand_input":
        return _expand_context_input_sync(req["cwd"], req.get("text", ""))

    if op == "context_load_file_slice":
        return _load_file_slice(req["cwd"], req.get("mention", ""), req.get("lineRange"))

    if op == "context_run_inline_command":
        return {"result": _run_inline_command(req["cwd"], req.get("command", ""))}

    # --- approval display ops ---

    if op == "approval_display_format":
        return {"result": _format_approval_display(
            req["toolName"], req.get("params", {}), req.get("subagentName"),
        )}

    # --- completions ops ---

    if op == "completions_get_suggestions":
        return {"result": _get_suggestions(
            req.get("inputText", ""),
            auth_step_kind=req.get("authStepKind", ""),
            providers=req.get("providers"),
            models=req.get("models"),
            auth_options=req.get("authOptions"),
            file_paths=req.get("filePaths"),
            custom_commands=req.get("customCommands"),
            cursor_position=req.get("cursorPosition"),
        )}

    # --- overlay rows ops ---

    if op == "overlay_task_status_icon":
        return {"result": _task_status_icon(req.get("status", "pending"))}

    if op == "overlay_format_task_row":
        return {"result": _format_task_overlay_row(
            req.get("task", {}), req.get("index", 0),
        )}

    if op == "overlay_format_tasks_header":
        return {"result": _format_tasks_overlay_header(req.get("tasks", []))}

    if op == "frontmatter_parse_batch":
        items = req.get("items", [])
        results = []
        for item in items:
            r = _parse_frontmatter(item.get("content", ""))
            results.append({"frontmatter": r.frontmatter, "body": r.body})
        return {"result": results}

    # --- checkpoints ops ---

    if op == "checkpoints_dir":
        return {"result": _checkpoints_dir(req["cwd"])}

    if op == "checkpoint_validate_name":
        return {"result": _validate_checkpoint_name(req.get("name", ""))}

    if op == "checkpoint_get_modified_files":
        return {"result": _get_modified_files(req["cwd"])}

    if op == "checkpoint_create":
        return {"result": _create_checkpoint(
            req["cwd"],
            req.get("messages", []),
            req.get("provider", "unknown"),
            req.get("model", "unknown"),
            req.get("name"),
            req.get("modifiedFiles"),
        )}

    if op == "checkpoint_load":
        return {"result": _load_checkpoint(req["cwd"], req["name"])}

    if op == "checkpoint_list":
        return {"result": _list_checkpoints(req["cwd"])}

    if op == "checkpoint_delete":
        _delete_checkpoint(req["cwd"], req["name"])
        return {"result": True}

    if op == "checkpoint_restore_files":
        _restore_checkpoint_files(req["cwd"], req.get("snapshots", {}))
        return {"result": True}

    if op == "checkpoint_format_relative_time":
        return {"result": _format_relative_time(req.get("timestamp", ""))}

    if op == "checkpoint_format_overlay_row":
        return {"result": _format_checkpoint_overlay_row(req.get("item", {}))}

    if op == "checkpoint_format_list":
        return {"result": _format_checkpoint_list(req.get("items", []))}

    # --- workflows ops ---

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
