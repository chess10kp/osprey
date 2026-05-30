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
    "core",
    "session",
    "auth",
    "cli",
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
    boot_batch as _boot_batch,
    session_boot_batch as _session_boot_batch,
)
from _frontmatter_toolchain import (  # noqa: E402
    parse_frontmatter as _parse_frontmatter,
    frontmatter_string as _frontmatter_string,
    frontmatter_string_list as _frontmatter_string_list,
)
from _subagents_toolchain import (  # noqa: E402
    resolve_jackal_root as _resolve_jackal_root,
    is_existing_dir as _is_existing_dir,
    load_agent_file as _load_agent_file,
    load_agents_from_dir as _load_agents_from_dir,
    discover_subagent_dirs as _discover_subagent_dirs,
    load_subagents as _load_subagents,
    list_subagents as _list_subagents,
    get_subagent as _get_subagent,
    load_settings_model_overrides as _load_settings_model_overrides,
    load_project_model_overrides as _load_project_model_overrides,
    normalize_allowed_tool_names as _normalize_allowed_tool_names,
    filter_tools_for_subagent as _filter_tools_for_subagent,
    format_subagent_catalog as _format_subagent_catalog,
    SUBAGENT_TOOL_ALIASES as _SUBAGENT_TOOL_ALIASES,
    EXCLUDED_SUBAGENT_TOOLS as _EXCLUDED_SUBAGENT_TOOLS,
)
from _chains_toolchain import (  # noqa: E402
    parse_chain_markdown as _parse_chain_markdown,
    list_chain_files as _list_chain_files,
    discover_chain_dirs as _discover_chain_dirs,
    load_chains as _load_chains,
    list_chains as _list_chains,
    get_chain as _get_chain,
    format_chain_catalog as _format_chain_catalog,
    chain_dirs_exist as _chain_dirs_exist,
)
from _subagent_runner_toolchain import (  # noqa: E402
    extract_assistant_summary as _extract_assistant_summary,
    count_tool_calls as _count_tool_calls,
    substitute_chain_template as _substitute_chain_template,
    build_step_prompt as _build_step_prompt,
    build_subagent_tool_description as _build_subagent_tool_description,
    MAX_PARALLEL_SUBAGENTS as _MAX_PARALLEL_SUBAGENTS,
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
from _mermaid_render_toolchain import (
    render_mermaid_ascii as _render_mermaid,
    detect_diagram_type as _detect_diagram_type,
)  # noqa: E402
from _overlay_rows_toolchain import (  # noqa: E402
    task_status_icon as _task_status_icon,
    format_task_overlay_row as _format_task_overlay_row,
    format_tasks_overlay_header as _format_tasks_overlay_header,
)
from _skills_toolchain import (  # noqa: E402
    load_skills_from_dir as _load_skills_from_dir,
    load_jackal_skills as _load_jackal_skills,
    format_skills_for_prompt as _format_skills_for_prompt,
    append_skills_to_prompt as _append_skills_to_prompt,
    expand_skill_command as _expand_skill_command,
    load_skill_by_dir as _load_skill_by_dir,
    skill_read_allowlist as _skill_read_allowlist,
)
from _project_init_toolchain import (  # noqa: E402
    analyze_project as _analyze_project,
    generate_agents_md as _generate_agents_md,
    run_project_init as _run_project_init,
)
from _mcp_schema_toolchain import (  # noqa: E402
    mcp_input_schema_to_parameters as _mcp_input_schema_to_parameters,
    coerce_by_schema as _coerce_by_schema,
    validate_and_coerce_args as _validate_and_coerce_args,
)
from _task_tools_toolchain import (  # noqa: E402
    validate_create_tasks as _validate_create_tasks,
    validate_update_tasks as _validate_update_tasks,
    validate_delete_tasks as _validate_delete_tasks,
    build_create_result as _build_create_result,
    build_update_result as _build_update_result,
    build_list_result as _build_list_result,
    build_delete_result as _build_delete_result,
)
from _web_tools_toolchain import (  # noqa: E402
    brave_api_key as _brave_api_key,
    assert_safe_fetch_url as _assert_safe_fetch_url,
    html_to_readable_text as _html_to_readable_text,
    format_web_search_results as _format_web_search_results,
    parse_brave_search_response as _parse_brave_search_response,
    search_web as _search_web,
    fetch_web_page as _fetch_web_page,
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
from _tool_summary_toolchain import (  # noqa: E402
    normalize_tool_input as _normalize_tool_input,
    tool_input_field as _tool_input_field,
    tool_bash_command as _tool_bash_command,
    tool_file_path as _tool_file_path,
    format_tool_summary as _format_tool_summary,
    enrich_tool_input_from_result as _enrich_tool_input_from_result,
    tool_event_input as _tool_event_input,
)
from _auto_compact_toolchain import (  # noqa: E402
    resolve_auto_compact_config as _resolve_auto_compact_config,
    build_mechanical_summary as _build_mechanical_summary,
    should_auto_compact as _should_auto_compact,
    build_llm_summary_prompt as _build_llm_summary_prompt,
    DEFAULT_AUTO_COMPACT as _DEFAULT_AUTO_COMPACT,
)
from _session_index_toolchain import (  # noqa: E402
    is_valid_session_id as _is_valid_session_id,
    migrate_legacy_latest as _migrate_legacy_latest,
    save_session_record as _save_session_record,
    list_sessions as _list_sessions,
    load_session_by_id as _load_session_by_id,
    resolve_session_target as _resolve_session_target,
    get_last_session as _get_last_session,
    delete_session as _delete_session,
    prune_sessions as _prune_sessions,
    rebuild_index as _rebuild_index,
)
from _session_persistence_toolchain import (  # noqa: E402
    session_dir_path as _session_dir_path,
    export_session_markdown as _export_session_markdown,
    save_compaction_backup as _save_compaction_backup,
    load_compaction_backup as _load_compaction_backup,
    clear_compaction_backup as _clear_compaction_backup,
    flush_session_record as _flush_session_record,
)
from _auth_flow_toolchain import (  # noqa: E402
    validate_provider_entry as _validate_provider_entry,
    validate_model_entry as _validate_model_entry,
    filter_providers_by_query as _filter_providers_by_query,
    filter_models_by_query as _filter_models_by_query,
    format_auth_provider_label as _format_auth_provider_label,
    format_model_label as _format_model_label,
    initial_auth_flow_state as _initial_auth_flow_state,
    transition_auth_flow as _transition_auth_flow,
)
from _auth_io_toolchain import (  # noqa: E402
    resolve_auth_path as _resolve_auth_path,
    load_auth_file as _load_auth_file,
    save_auth_file as _save_auth_file,
    get_auth_status as _get_auth_status,
)
from _path_resolve_toolchain import (  # noqa: E402
    safe_resolve as _safe_resolve,
    resolve_read_path as _resolve_read_path,
    format_post_write_message as _format_post_write_message,
)

from _adapter_helpers_toolchain import (  # noqa: E402
    resolve_context_max as _resolve_context_max,
    session_storage_dir as _session_storage_dir,
)
from _agent_busy_toolchain import is_agent_busy as _is_agent_busy  # noqa: E402
from _store_types_toolchain import (  # noqa: E402
    AGENT_PHASES as _AGENT_PHASES,
    MAX_TOOL_EXECUTIONS as _MAX_TOOL_EXECUTIONS,
    STREAM_EMIT_MS as _STREAM_EMIT_MS,
    INITIAL_SNAPSHOT as _INITIAL_SNAPSHOT,
    agent_messages_to_transcript as _agent_messages_to_transcript,
    tool_result_display_text as _tool_result_display_text,
    format_tool_payload as _format_tool_payload_store,
    tool_result_status as _tool_result_status_store,
    agent_message_to_store as _agent_message_to_store,
    agent_messages_to_store as _agent_messages_to_store,
    build_seed_data as _build_seed_data,
)
from _llm_compact_toolchain import wrap_compaction_summary as _wrap_compaction_summary  # noqa: E402
from _outbound_queue_toolchain import OutboundMessageQueue as _OutboundMessageQueue  # noqa: E402
from _lsp_helpers_toolchain import (  # noqa: E402
    parse_check_output as _parse_check_output_lsp,
    extract_symbol as _extract_symbol,
    escape_regex as _escape_regex,
    format_lsp_diagnostics as _format_lsp_diagnostics,
    format_hover_info as _format_hover_info,
    format_locations as _format_locations,
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

    if op == "boot_batch":
        return {"result": _boot_batch(req["cwd"])}

    if op == "session_boot_batch":
        return {"result": _session_boot_batch(req["cwd"], req.get("projectConfig", {}))}

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

    # --- skills ops ---

    if op == "skills_load_from_dir":
        result = _load_skills_from_dir(req["dir"], req.get("source", "path"))
        return {"result": {
            "skills": [
                {"name": s.name, "description": s.description,
                 "filePath": s.filePath, "baseDir": s.baseDir,
                 "source": s.source, "disableModelInvocation": s.disableModelInvocation}
                for s in result.skills
            ],
            "diagnostics": [
                {"type": d.type, "message": d.message, "path": d.path,
                 "collision": d.collision}
                for d in result.diagnostics
            ],
        }}

    if op == "skills_load_jackal":
        result = _load_jackal_skills(
            cwd=req.get("cwd"),
            package_root=req.get("packageRoot"),
            agent_dir=req.get("agentDir"),
            skill_paths=req.get("skillPaths"),
            include_defaults=req.get("includeDefaults", True),
        )
        return {"result": {
            "skills": [
                {"name": s.name, "description": s.description,
                 "filePath": s.filePath, "baseDir": s.baseDir,
                 "source": s.source, "disableModelInvocation": s.disableModelInvocation}
                for s in result.skills
            ],
            "diagnostics": [
                {"type": d.type, "message": d.message, "path": d.path,
                 "collision": d.collision}
                for d in result.diagnostics
            ],
        }}

    if op == "skills_format_for_prompt":
        skills = [
            type('Skill', (), {
                'name': s['name'], 'description': s['description'],
                'filePath': s['filePath'], 'baseDir': s['baseDir'],
                'source': s['source'], 'disableModelInvocation': s.get('disableModelInvocation', False),
            })()
            for s in (req.get("skills") or [])
        ]
        return {"result": _format_skills_for_prompt(skills)}

    if op == "skills_append_to_prompt":
        skills = [
            type('Skill', (), {
                'name': s['name'], 'description': s['description'],
                'filePath': s['filePath'], 'baseDir': s['baseDir'],
                'source': s['source'], 'disableModelInvocation': s.get('disableModelInvocation', False),
            })()
            for s in (req.get("skills") or [])
        ]
        return {"result": _append_skills_to_prompt(req.get("systemPrompt", ""), skills)}

    if op == "skills_expand_command":
        skills = [
            type('Skill', (), {
                'name': s['name'], 'description': s['description'],
                'filePath': s['filePath'], 'baseDir': s['baseDir'],
                'source': s['source'], 'disableModelInvocation': s.get('disableModelInvocation', False),
            })()
            for s in (req.get("skills") or [])
        ]
        return {"result": _expand_skill_command(req.get("text", ""), skills)}

    if op == "skills_load_by_dir":
        return {"result": _load_skill_by_dir(
            req["dirName"], req.get("packageRoot"),
        )}

    if op == "skills_read_allowlist":
        skills = [
            type('Skill', (), {
                'name': s['name'], 'description': s['description'],
                'filePath': s['filePath'], 'baseDir': s['baseDir'],
                'source': s['source'], 'disableModelInvocation': s.get('disableModelInvocation', False),
            })()
            for s in (req.get("skills") or [])
        ]
        return {"result": _skill_read_allowlist(skills)}

    # --- project init ops ---

    if op == "project_init_analyze":
        return {"result": _analyze_project(req["cwd"])}

    if op == "project_init_generate_agents_md":
        return {"result": _generate_agents_md(req.get("info", {}))}

    if op == "project_init_run":
        return {"result": _run_project_init(
            req["cwd"], force=req.get("force", False), lean=req.get("lean", False),
        )}

    # --- MCP schema ops ---

    if op == "mcp_schema_to_parameters":
        return {"result": _mcp_input_schema_to_parameters(req.get("schema"))}

    if op == "mcp_coerce_by_schema":
        return {"result": _coerce_by_schema(req.get("value"), req.get("schema", {}))}

    if op == "mcp_validate_and_coerce":
        return {"result": _validate_and_coerce_args(req.get("schema"), req.get("raw", {}))}

    # --- task tools ops ---

    if op == "task_tools_validate_create":
        return {"result": _validate_create_tasks(req.get("params", {}))}

    if op == "task_tools_validate_update":
        return {"result": _validate_update_tasks(req.get("params", {}))}

    if op == "task_tools_validate_delete":
        return {"result": _validate_delete_tasks(req.get("params", {}))}

    if op == "task_tools_build_create":
        return {"result": _build_create_result(req["cwd"], req.get("inputs", []))}

    if op == "task_tools_build_update":
        return {"result": _build_update_result(req["cwd"], req.get("updates", []))}

    if op == "task_tools_build_list":
        return {"result": _build_list_result(
            req["cwd"], req.get("status", "all"),
        )}

    if op == "task_tools_build_delete":
        return {"result": _build_delete_result(req["cwd"], req.get("params", {}))}

    # --- web tools ops ---

    if op == "web_brave_api_key":
        return {"result": _brave_api_key()}

    if op == "web_assert_safe_url":
        _assert_safe_fetch_url(req.get("url", ""))
        return {"result": True}

    if op == "web_html_to_text":
        return {"result": _html_to_readable_text(req.get("html", ""))}

    if op == "web_format_search_results":
        return {"result": _format_web_search_results(req.get("results", []))}

    if op == "web_search":
        return {"result": _search_web(req["query"], req.get("count"))}

    if op == "web_fetch":
        return {"result": _fetch_web_page(
            req["url"], req.get("timeout"),
        )}

    # ── Core: tool summary ──────────────────────────────────────────
    if op == "tool_summary_normalize_input":
        return {"result": _normalize_tool_input(req.get("raw"))}
    if op == "tool_summary_format":
        return {"result": _format_tool_summary(req.get("toolName", ""), req.get("input"))}
    if op == "tool_summary_file_path":
        return {"result": _tool_file_path(req.get("input"))}
    if op == "tool_summary_bash_command":
        return {"result": _tool_bash_command(req.get("input"))}
    if op == "tool_summary_enrich":
        return {"result": _enrich_tool_input_from_result(
            req.get("toolName", ""), req.get("input"), req.get("result"),
        )}
    if op == "tool_summary_event_input":
        return {"result": _tool_event_input(req.get("event", {}))}

    # ── Session: auto-compact ───────────────────────────────────────
    if op == "auto_compact_resolve_config":
        return {"result": _resolve_auto_compact_config(req.get("raw", {}))}
    if op == "auto_compact_should_trigger":
        cfg = req.get("config", _DEFAULT_AUTO_COMPACT)
        return {"result": _should_auto_compact(req.get("usagePercent", 0), cfg)}
    if op == "auto_compact_build_mechanical_summary":
        return {"result": _build_mechanical_summary(req.get("messages", []))}
    if op == "auto_compact_build_llm_prompt":
        return {"result": _build_llm_summary_prompt(req.get("messages", []))}

    # ── Session: index / persistence ────────────────────────────────
    if op == "session_list":
        return {"result": _list_sessions(req["sessionDir"], req.get("options"))}
    if op == "session_load":
        return {"result": _load_session_by_id(req["sessionDir"], req["id"])}
    if op == "session_save":
        _save_session_record(req["sessionDir"], req["record"])
        return {"result": True}
    if op == "session_delete":
        return {"result": _delete_session(req["sessionDir"], req["id"])}
    if op == "session_last":
        return {"result": _get_last_session(req["sessionDir"], req.get("options"))}
    if op == "session_resolve_target":
        return {"result": _resolve_session_target(
            req["sessionDir"], req["target"], req.get("options"),
        )}
    if op == "session_prune":
        return {"result": _prune_sessions(req["sessionDir"], req.get("options"))}
    if op == "session_migrate_legacy":
        return {"result": _migrate_legacy_latest(req["sessionDir"], req["cwd"])}
    if op == "session_rebuild_index":
        return {"result": _rebuild_index(req["sessionDir"])}
    if op == "session_is_valid_id":
        return {"result": _is_valid_session_id(req.get("id", ""))}

    # ── Session: persistence helpers ────────────────────────────────
    if op == "session_dir_path":
        return {"result": _session_dir_path(req["cwd"], req.get("subdir"))}
    if op == "session_export_markdown":
        return {"result": _export_session_markdown(
            req["sessionId"], req["sessionName"], req["cwd"],
            req.get("modelRef"), req.get("messages", []),
        )}
    if op == "session_save_compaction_backup":
        _save_compaction_backup(req["sessionDir"], req["sessionId"], req.get("messages", []))
        return {"result": True}
    if op == "session_load_compaction_backup":
        return {"result": _load_compaction_backup(req["sessionDir"], req["sessionId"])}
    if op == "session_clear_compaction_backup":
        _clear_compaction_backup(req["sessionDir"], req["sessionId"])
        return {"result": True}
    if op == "session_flush_record":
        _flush_session_record(
            req["sessionDir"], req["sessionId"], req["sessionName"],
            req["cwd"], req["createdAt"], req.get("messages", []),
            req.get("modelRef"),
        )
        return {"result": True}

    if op == "auth_validate_provider":
        return {"result": _validate_provider_entry(req.get("entry"))}
    if op == "auth_validate_model":
        return {"result": _validate_model_entry(req.get("entry"))}
    if op == "auth_filter_providers":
        return {"result": _filter_providers_by_query(req.get("providers", []), req.get("query", ""))}
    if op == "auth_filter_models":
        return {"result": _filter_models_by_query(
            req.get("models", []), req.get("query", ""), req.get("providerFilter"),
        )}
    if op == "auth_format_provider_label":
        return {"result": _format_auth_provider_label(req.get("entry", {}))}
    if op == "auth_format_model_label":
        return {"result": _format_model_label(req.get("entry", {}))}
    if op == "auth_initial_state":
        return {"result": _initial_auth_flow_state()}
    if op == "auth_transition":
        return {"result": _transition_auth_flow(
            req.get("state", {}), req.get("action", ""), req.get("payload"),
        )}

    # ── Auth: I/O ────────────────────────────────────────────────
    if op == "auth_resolve_path":
        return {"result": _resolve_auth_path(req.get("agentDir"))}
    if op == "auth_load_file":
        return {"result": _load_auth_file(req["path"])}
    if op == "auth_save_file":
        _save_auth_file(req["path"], req.get("data", {}))
        return {"result": True}
    if op == "auth_get_status":
        return {"result": _get_auth_status(
            req["provider"], req.get("storedProviders", {}),
            req.get("runtimeKeys"), req.get("envApiKey"),
        )}

    # ── Orchestration: subagents ──────────────────────────────────
    if op == "subagent_resolve_root":
        return {"result": _resolve_jackal_root(req.get("agentDir"))}
    if op == "subagent_discover_dirs":
        return {"result": _discover_subagent_dirs(req["cwd"], req.get("agentDir"))}
    if op == "subagent_list":
        return {"result": _list_subagents(req["cwd"], req.get("agentDir"))}
    if op == "subagent_get":
        return {"result": _get_subagent(req["cwd"], req["name"], req.get("agentDir"))}
    if op == "subagent_load":
        return {"result": dict(_load_subagents(req["cwd"], req.get("agentDir")))}
    if op == "subagent_settings_overrides":
        return {"result": _load_settings_model_overrides(req.get("agentDir"))}
    if op == "subagent_project_overrides":
        return {"result": _load_project_model_overrides(req["cwd"])}
    if op == "subagent_normalize_tools":
        return {"result": sorted(_normalize_allowed_tool_names(req.get("tools"))) if _normalize_allowed_tool_names(req.get("tools")) else None}
    if op == "subagent_filter_tools":
        return {"result": _filter_tools_for_subagent(req.get("allToolNames", []), req.get("allowedNames"))}
    if op == "subagent_format_catalog":
        return {"result": _format_subagent_catalog(req["cwd"], req.get("agentDir"))}
    if op == "subagent_load_agent_file":
        return {"result": _load_agent_file(req["filePath"], req.get("source", "package"))}

    # ── Orchestration: chains ──────────────────────────────────────
    if op == "chain_parse_markdown":
        return {"result": _parse_chain_markdown(req["content"], req.get("source", "package"), req.get("filePath", ""))}
    if op == "chain_discover_dirs":
        return {"result": _discover_chain_dirs(req["cwd"], req.get("agentDir"))}
    if op == "chain_list":
        return {"result": _list_chains(req["cwd"], req.get("agentDir"))}
    if op == "chain_get":
        return {"result": _get_chain(req["cwd"], req["name"], req.get("agentDir"))}
    if op == "chain_load":
        return {"result": dict(_load_chains(req["cwd"], req.get("agentDir")))}
    if op == "chain_format_catalog":
        return {"result": _format_chain_catalog(req["cwd"], req.get("agentDir"))}
    if op == "chain_dirs_exist":
        return {"result": _chain_dirs_exist(req["cwd"], req.get("agentDir"))}

    # ── Orchestration: runner helpers ──────────────────────────────
    if op == "runner_extract_summary":
        return {"result": _extract_assistant_summary(req.get("messages", []))}
    if op == "runner_count_tool_calls":
        return {"result": _count_tool_calls(req.get("messages", []))}
    if op == "runner_substitute_template":
        return {"result": _substitute_chain_template(req["template"], req.get("task", ""), req.get("previous", ""))}
    if op == "runner_build_step_prompt":
        return {"result": _build_step_prompt(req["step"], req.get("task", ""), req.get("previous", ""))}
    if op == "runner_build_tool_description":
        return {"result": _build_subagent_tool_description(req["cwd"], req.get("agentDir"))}

    # ── CLI: run helpers ─────────────────────────────────────────
    if op == "cli_resolve_run_mode":
        from _run_toolchain import resolve_run_mode
        return {"result": resolve_run_mode(req.get("cwd", ""), req.get("cliMode"))}
    if op == "cli_parse_run_args":
        from _run_toolchain import parse_run_args
        return {"result": parse_run_args(req.get("argv", []))}
    if op == "cli_format_tool_line":
        from _run_toolchain import format_tool_line
        return {"result": format_tool_line(req.get("toolName", ""), req.get("input"))}
    if op == "cli_last_assistant_text":
        from _run_toolchain import last_assistant_text
        return {"result": last_assistant_text(req.get("messages", []))}
    if op == "cli_approval_message":
        from _run_toolchain import approval_message
        return {"result": approval_message(req.get("toolName", ""), req.get("subagentName"))}

    # ── Agent: path resolve ──────────────────────────────────────────
    if op == "path_safe_resolve":
        return {"result": _safe_resolve(req["cwd"], req["inputPath"])}
    if op == "path_resolve_read":
        return {"result": _resolve_read_path(
            req["cwd"], req["inputPath"],
            allow_files=set(req.get("allowFiles", [])) or None,
            allow_roots=set(req.get("allowRoots", [])) or None,
        )}
    if op == "path_format_post_write":
        return {"result": _format_post_write_message(
            req.get("action", "Wrote"), req.get("path", ""), req.get("notes"),
        )}

    # ── Core: adapter helpers ────────────────────────────────────────
    if op == "adapter_resolve_context_max":
        return {"result": _resolve_context_max(
            req["cwd"], req.get("options"), req.get("envValue"), req.get("projectConfig"),
        )}
    if op == "adapter_session_storage_dir":
        return {"result": _session_storage_dir(req["cwd"], req.get("override"))}

    # ── Core: agent busy ────────────────────────────────────────────
    if op == "core_is_agent_busy":
        return {"result": _is_agent_busy(req.get("snapshot", {}))}

    # ── Core: store types / bridge helpers ──────────────────────────
    if op == "store_agent_phases":
        return {"result": list(_AGENT_PHASES)}
    if op == "store_max_tool_executions":
        return {"result": _MAX_TOOL_EXECUTIONS}
    if op == "store_stream_emit_ms":
        return {"result": _STREAM_EMIT_MS}
    if op == "store_initial_snapshot":
        return {"result": dict(_INITIAL_SNAPSHOT)}
    if op == "store_messages_to_transcript":
        return {"result": _agent_messages_to_transcript(req.get("messages", []))}
    if op == "store_tool_result_display_text":
        return {"result": _tool_result_display_text(req.get("value"))}
    if op == "store_format_tool_payload":
        return {"result": _format_tool_payload_store(req.get("value"))}
    if op == "store_tool_result_status":
        return {"result": _tool_result_status_store(req.get("value"), req.get("isError"))}
    if op == "store_agent_message_to_store":
        return {"result": _agent_message_to_store(req.get("message", {}))}
    if op == "store_agent_messages_to_store":
        return {"result": _agent_messages_to_store(req.get("messages", []))}
    if op == "store_build_seed_data":
        return {"result": _build_seed_data(
            req.get("mode", "normal"), req.get("provider", ""),
            req.get("model", ""), req.get("sessionId", ""),
            req.get("sessionName", ""), req.get("messages"),
        )}

    # ── Session: LLM compact ────────────────────────────────────────
    if op == "session_wrap_compaction_summary":
        return {"result": _wrap_compaction_summary(req.get("text", ""))}

    # ── Session: outbound queue ──────────────────────────────────────
    if op == "queue_new":
        q = _OutboundMessageQueue()
        return {"result": q.to_dict()}
    if op == "queue_peek":
        q = _OutboundMessageQueue.from_dict(req.get("data", {}))
        return {"result": q.peek()}
    if op == "queue_enqueue":
        q = _OutboundMessageQueue.from_dict(req.get("data", {}))
        q.enqueue(req.get("text", ""))
        return {"result": q.to_dict()}
    if op == "queue_dequeue":
        q = _OutboundMessageQueue.from_dict(req.get("data", {}))
        item = q.dequeue()
        return {"result": {"item": item, "queue": q.to_dict()}}
    if op == "queue_clear":
        q = _OutboundMessageQueue.from_dict(req.get("data", {}))
        q.clear()
        return {"result": q.to_dict()}
    if op == "queue_length":
        q = _OutboundMessageQueue.from_dict(req.get("data", {}))
        return {"result": q.length}

    # ── LSP helpers ──────────────────────────────────────────────────
    if op == "lsp_parse_check_output":
        return {"result": _parse_check_output_lsp(
            req.get("output", ""), req.get("defaultFile"),
        )}
    if op == "lsp_extract_symbol":
        return {"result": _extract_symbol(req.get("line", ""), req.get("character", 0))}
    if op == "lsp_escape_regex":
        return {"result": _escape_regex(req.get("str", ""))}
    if op == "lsp_format_diagnostics":
        return {"result": _format_lsp_diagnostics(req.get("diagnostics", []))}
    if op == "lsp_format_hover_info":
        return {"result": _format_hover_info(req.get("info", {}))}
    if op == "lsp_format_locations":
        return {"result": _format_locations(
            req.get("locations", []), req.get("label", "Results"),
        )}

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
