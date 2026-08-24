"""Slash-command routing through builtins and extension commands."""

import from agent.session { plugins, session_boot, session_dispose }
import from agent.plugin_bridge {
    PluginBridge,
    create_bridge,
    dispose_bridge,
}
import from agent.fake_host {
    ensure_host,
    register_fake_command,
}


def _upper(args: str, ctx: any) -> str {
    out = str(args).strip().upper();
    ctx["ui"].notify("UPPER:" + out);
    return out;
}


def _with_fake_bridge -> PluginBridge {
    b = create_bridge("main-cmd-test");
    plugins.bridge = b;
    ensure_host(b);
    register_fake_command(b, "upper", _upper, description="Uppercase args");
    return b;
}


test "handle_command builtins" {
    assert handle_command("/clear") == "history cleared";
    assert handle_command("/model ") == "usage: /model NAME";
    assert handle_command("/help") == "";
    assert handle_command("/exit") is None;
    # No turn in flight -> abort is a no-op with a clear reply.
    assert handle_command("/abort") == "no active turn";
}


test "handle_command routes slash args into extension commands" {
    b = _with_fake_bridge();
    try {
        reply = handle_command("/upper hello main");
        assert reply is not None;
        assert "UPPER:HELLO MAIN" in reply;
        assert "HELLO MAIN" in reply;

        listing = handle_command("/commands");
        assert listing is not None;
        assert "extension commands:" in listing;
        assert "/upper  Uppercase args" in listing;

        # Unknown names still fail loud, now with the /commands hint.
        miss = handle_command("/nope");
        assert miss is not None;
        assert miss.startswith("unknown command:");
        assert "/commands" in miss;

        # Non-slash text is not a command.
        assert handle_command("plain text") == "";
    } finally {
        plugins.bridge = None;
        dispose_bridge(b);
    }
}


test "session_boot dispose round trip (no extensions)" {
    import os;
    import tempfile;
    import shutil;

    # Empty cwd -> no .jackal/extensions.json -> idle phase, bridge is None.
    tmp = tempfile.mkdtemp(prefix="jackal-main-boot-");
    old_cwd = os.getcwd();
    os.chdir(tmp);
    try {
        st = session_boot("main-boot-test", tmp);
        assert st.total == 0;
        assert st.phase == "idle";
        assert plugins.bridge is None;
    } finally {
        session_dispose();
        os.chdir(old_cwd);
        shutil.rmtree(tmp, ignore_errors=True);
    }
    assert plugins.bridge is None;
    assert plugins.reg is None;
}


test "handle_command sessions resume export round-trip" {
    import os;
    import tempfile;
    import shutil;
    import from agent.sessions { save_session }

    tmp = tempfile.mkdtemp(prefix="jackal-main-sess-");
    old_cwd = os.getcwd();
    os.chdir(tmp);
    checks: list[str] = [];
    try {
        hist = [
            {"role": "system", "content": "sys"},
            {"role": "user", "content": "hello"},
            {"role": "assistant", "content": "hi there"},
        ];
        meta = save_session(tmp, hist, name="round trip",
                            model="test/model-x");
        sid = str(meta["id"]);

        listing = handle_command("/sessions");
        assert listing is not None;
        checks.append("listing-has-sid=" + str(sid in listing));
        checks.append("listing-has-name=" + str("round trip" in listing));

        clear_history();
        reply = handle_command("/resume");
        checks.append("resume-reply=" + repr(reply)[:120]);
        checks.append("reply-has-model=" + str("model -> test/model-x" in str(reply)));

        r2 = handle_command("/resume " + sid);
        checks.append("resume-by-id=" + str("resumed" in str(r2)));
        r3 = handle_command("/resume sess_42");
        checks.append("resume-unknown=" + repr(r3));

        out = os.path.join(tmp, "out.md");
        exp = handle_command("/export " + out);
        checks.append("export-reply=" + repr(exp));
        exists = os.path.exists(out);
        checks.append("out-exists=" + str(exists));
        body = "";
        if exists {
            fh = open(out, "r");
            try {
                body = fh.read();
            } finally {
                fh.close();
            }
            checks.append("body-has-user=" + str("hello" in body));
        }

        clear_history();
        empty_reply = handle_command("/export");
        checks.append("empty-export=" + repr(empty_reply));
    } finally {
        os.chdir(old_cwd);
        shutil.rmtree(tmp, ignore_errors=True);
    }
    for c in checks {
        assert not c.endswith("=False"), "failed check: " + c;
    }
}
