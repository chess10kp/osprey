"""Keybinding precedence tests.

The precedence guard under test is a verbatim replica of tui._handle_key's
branch order (tui/shell.jac cannot be imported headless - see keybinding_probe.jac).
Everything BEHIND the guard is real: agent.session.list_extension_shortcuts,
run_extension_shortcut, and the fake plugin host bridge.
"""

test "extension shortcut shadows navigation key and carries result" {
    (app, bridge, fired) = make_key_probe([("up", "probe result")]);
    try {
        # Listing is filtered to exactly the registered binding.
        scs = list_extension_shortcuts();
        assert list(scs.keys()) == ["up"];
        assert scs["up"]["description"] == "Probe up";
        assert scs["up"]["extension_id"] == "fake.shortcuts";

        # "up" would hit history navigation in the real shell; the registered
        # shortcut must shadow it and claim the keypress.
        probe_handle_key(app, "up");
        assert len(fired) == 1;
        assert app.status_hint == "shortcut up — Probe up";
        assert app.dirty is True;
        assert app.running is True;  # not a quit path
        assert app.tool_replies == ["probe result"];  # handler result rides back
    } finally {
        drop_key_probe(bridge);
    }
}


test "ctrl+c keeps precedence over a registered shortcut" {
    (app, bridge, fired) = make_key_probe([("ctrl+c", "never")]);
    try {
        assert len(list(list_extension_shortcuts().keys())) == 1;
        probe_handle_key(app, "ctrl+c");
        assert app.running is False;
        assert len(fired) == 0;  # quit branch returns before shortcut match
        assert app.status_hint == "";
    } finally {
        drop_key_probe(bridge);
    }
}


test "pending approval swallows shortcut keys" {
    (app, bridge, fired) = make_key_probe([("q", "never")]);
    try {
        app.approval = {"tool": "run_command"};  # non-None sentinel
        probe_handle_key(app, "q");
        # Approval branch matches no accept/reject key and returns before the
        # shortcut lookup: the binding must NOT fire while an approval is up.
        assert len(fired) == 0;
        assert app.status_hint == "";
        assert app.running is True;
    } finally {
        drop_key_probe(bridge);
    }
}


test "extension-UI modal swallows keys ahead of shortcuts" {
    (app, bridge, fired) = make_key_probe([("x", "never")]);
    try {
        app.ui_modal = True;  # modal open sentinel (replaced by the key)
        probe_handle_key(app, "x");
        assert app.ui_modal == "x";  # modal consumed the keypress
        assert len(fired) == 0;
    } finally {
        drop_key_probe(bridge);
    }
}


test "escape aborts streaming and quits an idle shell when unregistered" {
    (app, bridge, fired) = make_key_probe([("up", "unused")]);
    try {
        app.phase = "streaming";
        probe_handle_key(app, "escape");
        assert app.running is True;  # streaming escape aborts, does not quit
        assert app.status_hint == "aborting…";
        assert app.dirty is True;

        app.phase = "ready";
        probe_handle_key(app, "escape");
        assert app.running is False;  # idle escape = quit
    } finally {
        drop_key_probe(bridge);
    }
}
