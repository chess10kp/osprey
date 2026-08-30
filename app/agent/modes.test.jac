"""Dev-mode safety tests (ported from lib/jac/tests/test_phase2_leaf_modules.py).

Covers: mode cycling, read-only blocking across every mode, destructive
bash detection variants, approval policy resolution per mode, --mode flag
parsing, and system-prompt appendix behavior.

This file is tested merged with agent/modes.jac (same-stem convention), so
all symbols under test are referenced directly without imports.
"""


def _args1(a: str) -> list[str] {
    args: list[str] = [];
    args.append(a);
    return args;
}


def _args2(a: str, b: str) -> list[str] {
    args: list[str] = [];
    args.append(a);
    args.append(b);
    return args;
}

test "read-only modes are exactly plan and ask" {
    assert is_read_only_mode("plan");
    assert is_read_only_mode("ask");
    assert not is_read_only_mode("normal");
    assert not is_read_only_mode("auto-accept");
    assert not is_read_only_mode("yolo");
}


test "write-family tools are blocked in read-only mode" {
    assert is_tool_blocked_in_read_only_mode("write");
    assert is_tool_blocked_in_read_only_mode("edit");
    assert is_tool_blocked_in_read_only_mode("jac_format");
    assert is_tool_blocked_in_read_only_mode("jac_fix");
    assert is_tool_blocked_in_read_only_mode("jac_create");
    assert is_tool_blocked_in_read_only_mode("create_task");
    assert is_tool_blocked_in_read_only_mode("update_task");
    assert is_tool_blocked_in_read_only_mode("delete_task");
    assert is_tool_blocked_in_read_only_mode("format_jac");
    assert is_tool_blocked_in_read_only_mode("execute_command");
    assert not is_tool_blocked_in_read_only_mode("read_file");
    assert not is_tool_blocked_in_read_only_mode("bash");
    assert not is_tool_blocked_in_read_only_mode("list_dir");
}


test "is_tool_blocked applies only in read-only modes" {
    for mode in DEV_MODES {
        blocked = is_tool_blocked(mode, "write_file");
        if mode == "plan" or mode == "ask" {
            assert blocked;
        } else {
            assert not blocked;
        }
        assert not is_tool_blocked(mode, "read_file");
        assert not is_tool_blocked(mode, "list_dir");
    }
}


test "cycle_mode walks the full ring and resets unknown modes" {
    assert cycle_mode("normal") == "auto-accept";
    assert cycle_mode("auto-accept") == "yolo";
    assert cycle_mode("yolo") == "plan";
    assert cycle_mode("plan") == "ask";
    assert cycle_mode("ask") == "normal";
    assert cycle_mode("bogus") == "normal";
}


test "parse_mode_flag accepts both flag forms and valid values" {
    assert parse_mode_flag(_args2("--mode", "plan")) == "plan";
    assert parse_mode_flag(_args1("--mode=yolo")) == "yolo";
    assert parse_mode_flag(_args1("--mode=ask")) == "ask";
    assert parse_mode_flag(_args1("--verbose")) is None;
}


test "parse_mode_flag rejects invalid values with an error payload" {
    res = parse_mode_flag(_args2("--mode", "chaos"));
    res_dict: dict[str, str] = res as dict[str, str];
    assert res_dict.get("error", "") == "chaos";
    res2 = parse_mode_flag(_args1("--mode=nonsense"));
    res2_dict: dict[str, str] = res2 as dict[str, str];
    assert res2_dict.get("error", "") == "nonsense";
}


test "destructive bash variants are detected" {
    assert is_destructive_bash("rm -rf /");
    # Original-pattern semantics: lookahead excludes "/usr" (path-anchored).
    assert not is_destructive_bash("rm -rf /usr");
    assert is_destructive_bash("rm -rf ~");
    assert is_destructive_bash("rm -rf $HOME");
    assert is_destructive_bash("rm -rf ${HOME}");
    assert is_destructive_bash("sudo mkfs.ext4 /dev/sda1");
    assert is_destructive_bash("dd if=/dev/zero of=/dev/sda");
    assert is_destructive_bash("> /dev/sda");
    assert is_destructive_bash("chmod -R 000 /etc");
    assert is_destructive_bash("git reset --hard HEAD~3");
    assert is_destructive_bash("git push --force origin main");
    assert is_destructive_bash("git push -f");
    assert is_destructive_bash("git clean -fdx");
    assert is_destructive_bash("git branch -D feature");
    assert is_destructive_bash("git stash drop");
    assert is_destructive_bash("drop database prod;");
    assert is_destructive_bash("truncate table users;");
    assert is_destructive_bash("  RM -RF /  ");
}


test "benign commands are not flagged destructive" {
    assert not is_destructive_bash("");
    assert not is_destructive_bash("   ");
    assert not is_destructive_bash("ls -la");
    assert not is_destructive_bash("git status");
    assert not is_destructive_bash("git push origin main");
    assert not is_destructive_bash("rm -rf ./build");
    assert not is_destructive_bash("echo hello > out.txt");
}


test "yolo auto-approves everything including risky commands" {
    assert requires_approval("yolo", "read_file", "") == "auto";
    assert requires_approval("yolo", "write_file", "") == "auto";
    assert requires_approval("yolo", "edit_file", "") == "auto";
    assert requires_approval("yolo", "run_command", "") == "auto";
    assert requires_approval("yolo", "run_command", "rm -rf /") == "auto";
}


test "plan and ask block write family but auto-approve reads" {
    assert requires_approval("plan", "write_file", "") == "blocked";
    assert requires_approval("plan", "edit_file", "") == "blocked";
    assert requires_approval("plan", "write", "") == "blocked";
    assert requires_approval("plan", "edit", "") == "blocked";
    assert requires_approval("plan", "run_command", "rm -rf /") == "blocked";
    assert requires_approval("plan", "read_file", "") == "auto";
    assert requires_approval("plan", "list_dir", "") == "auto";
    assert requires_approval("plan", "run_command", "ls -la") == "auto";
    assert requires_approval("ask", "write_file", "") == "blocked";
    assert requires_approval("ask", "edit_file", "") == "blocked";
    assert requires_approval("ask", "write", "") == "blocked";
    assert requires_approval("ask", "edit", "") == "blocked";
    assert requires_approval("ask", "run_command", "rm -rf /") == "blocked";
    assert requires_approval("ask", "read_file", "") == "auto";
    assert requires_approval("ask", "list_dir", "") == "auto";
    assert requires_approval("ask", "run_command", "ls -la") == "auto";
}


test "auto-accept approves safe work but confirms destructive shell" {
    assert requires_approval("auto-accept", "write_file", "") == "auto";
    assert requires_approval("auto-accept", "edit_file", "") == "auto";
    assert requires_approval("auto-accept", "run_command", "npm test") == "auto";
    assert requires_approval("auto-accept", "run_command", "rm -rf /") == "confirm";
    assert requires_approval("auto-accept", "run_command", "git push --force") == "confirm";
}


test "normal mode confirms every executable call" {
    assert requires_approval("normal", "write_file", "") == "confirm";
    assert requires_approval("normal", "read_file", "") == "confirm";
    assert requires_approval("normal", "run_command", "ls") == "confirm";
}


test "unknown mode falls back to normal-mode confirmation" {
    assert requires_approval("", "write_file", "") == "confirm";
    assert requires_approval("bogus", "run_command", "rm -rf /") == "confirm";
    assert requires_approval("bogus", "read_file", "") == "confirm";
}


test "system prompt gains the matching appendix once per mode" {
    base = "You are helpful.";
    plan = system_prompt_for_mode(base, "plan");
    assert "## Plan mode (active)" in plan;
    assert system_prompt_for_mode(plan, "plan") == plan;
    ask = system_prompt_for_mode(base, "ask");
    assert "## Ask mode (active)" in ask;
    assert system_prompt_for_mode(ask, "ask") == ask;
    assert system_prompt_for_mode(base, "normal") == base;
    assert system_prompt_for_mode(base, "yolo") == base;
}


test "block reason names the tool and mode with a recovery hint" {
    r = read_only_mode_block_reason("write_file", "ask");
    assert "write_file" in r;
    assert "ask mode" in r;
    p = read_only_mode_block_reason("edit_file", "plan");
    assert "edit_file" in p;
    assert "plan mode" in p;
}
