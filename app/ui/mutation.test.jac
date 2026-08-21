"""Behavior tests for OSP UI graph structural mutations."""


test "append_child maintains sparse rank ordering" {
    screen = MainScreen(key="main");
    header = Header(key="header", title="Jackal");
    transcript = TranscriptView(key="transcript", source_id="session.events");
    status = Status(key="status", phase="ready");
    prompt = Prompt(key="prompt", draft="");

    append_child(screen, header);
    append_child(screen, transcript);
    append_child(screen, status);
    append_child(screen, prompt);

    assert ordered_child_keys(screen) == [
        "header",
        "transcript",
        "status",
        "prompt",
    ];
    assert child_rank(screen, transcript) > child_rank(screen, header);
    assert child_rank(screen, prompt) > child_rank(screen, status);
}


test "move_before reorders siblings without remounting unrelated nodes" {
    screen = MainScreen(key="main");
    header = Header(key="header");
    transcript = TranscriptView(key="transcript");
    status = Status(key="status");
    prompt = Prompt(key="prompt");

    append_child(screen, header);
    append_child(screen, transcript);
    append_child(screen, status);
    append_child(screen, prompt);

    move_before(prompt, header);
    assert ordered_child_keys(screen) == [
        "prompt",
        "header",
        "transcript",
        "status",
    ];
    assert child_parent(prompt) is screen;
    assert child_parent(header) is screen;
}


test "replace swaps one mounted node for another at the same slot" {
    screen = MainScreen(key="main");
    old_status = Status(key="status", phase="booting");
    prompt = Prompt(key="prompt");
    append_child(screen, old_status);
    append_child(screen, prompt);

    new_status = Status(key="status", phase="ready");
    replace(old_status, new_status);

    assert ordered_child_keys(screen) == ["status", "prompt"];
    assert new_status.phase == "ready";
    assert child_parent(old_status) is None;
}


test "append_child rejects duplicate sibling keys atomically" {
    screen = MainScreen(key="main");
    first = Header(key="dup");
    second = Header(key="dup");
    append_child(screen, first);
    failed = False;
    try {
        append_child(screen, second);
    } except ValueError {
        failed = True;
    }
    assert failed;
    assert ordered_child_keys(screen) == ["dup"];
}


test "detach and dispose_subtree clear containment without touching jid keys" {
    ui_root = UiSessionRoot(key="session");
    screen = MainScreen(key="main");
    prompt = Prompt(key="prompt", draft="hi");
    prompt_id = node_id(prompt);

    append_child(ui_root, screen);
    append_child(screen, prompt);
    detach(prompt);
    assert child_parent(prompt) is None;
    assert node_id(prompt) == prompt_id;

    dispose_subtree(ui_root);
    assert child_parent(screen) is None;
}
