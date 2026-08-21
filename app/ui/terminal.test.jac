"""Behavior tests for Terminal helpers (no TTY required)."""


test "read_terminal_size returns positive dimensions" {
    (cols, rows) = read_terminal_size();
    assert cols > 0;
    assert rows > 0;
}


test "control sequence constants are non-empty escapes" {
    assert ENTER_ALT_SCREEN.startswith("\x1b");
    assert LEAVE_ALT_SCREEN.startswith("\x1b");
    assert ENABLE_BRACKETED_PASTE.startswith("\x1b");
    assert DISABLE_BRACKETED_PASTE.startswith("\x1b");
    assert SYNC_BEGIN.startswith("\x1b");
    assert SYNC_END.startswith("\x1b");
    assert HIDE_CURSOR.startswith("\x1b");
    assert SHOW_CURSOR.startswith("\x1b");
}
