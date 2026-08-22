"""Slash-command routing through builtins and extension commands."""

import from agent.session { plugins }
import from agent.plugin_bridge {
    create_bridge,
    ensure_host,
    dispose_bridge,
    register_fake_command,
}


def _upper(args: str, ctx: any) -> str {
    out = str(args).strip().upper();
    ctx["ui"].notify("UPPER:" + out);
    return out;
}


def _with_fake_bridge {
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
        assert "UPPER:HELLO MAIN" in reply;
        assert "HELLO MAIN" in reply;

        listing = handle_command("/commands");
        assert "extension commands:" in listing;
        assert "/upper  Uppercase args" in listing;

        # Unknown names still fail loud, now with the /commands hint.
        miss = handle_command("/nope");
        assert miss.startswith("unknown command:");
        assert "/commands" in miss;

        # Non-slash text is not a command.
        assert handle_command("plain text") == "";
    } finally {
        plugins.bridge = None;
        dispose_bridge(b);
    }
}
