"""Session plugin boot + dual clocks + bridge wiring (P1/P2)."""

import os;
import time;
import tempfile;

import from .plugin_bridge {
    resolve_stub_echo,
    resolve_pi_greet,
    resolve_stub_commands,
    register_fake_command,
    register_fake_listener,
    create_bridge,
    ensure_host,
    fire_hook,
    PluginBridge,
}
import from .registry { invoke, get_tool, ToolRegistry }
import from .extensions { load_extension_decls }


test "session_boot with no decls never starts node" {
    session_dispose();
    st = session_boot("t-none", os.getcwd(), []);
    assert st.total == 0;
    assert st.ready;
    assert st.phase == "idle";
    assert plugins.bridge is None;
    assert st.t_interactive_s > 0.0;
    assert st.t_ext_ready_s > 0.0;
    session_dispose();
}


test "session_boot parallel sidecar loads fixture and run_turn uses bridge" {
    session_dispose();
    stub = resolve_stub_echo();
    t0 = time.time();
    st = session_boot(
        "t-side",
        os.getcwd(),
        [{"id": "stub.echo", "path": stub, "runtime": "node"}],
        wait_budget_s=10.0,
    );
    # First-frame clock is set immediately (parallel warm).
    assert st.t_interactive_s >= t0;
    assert st.total == 1;
    assert "loading" in st.label or st.ready or st.phase == "starting";
    ready = wait_extensions_ready(10.0);
    assert ready.loaded == 1;
    assert ready.ready;
    assert ready.t_ext_ready_s >= ready.t_interactive_s;
    assert plugins.bridge is not None;
    assert plugins.bridge.host_kind == "node";
    assert plugins.bridge.compat_tier in ("T0", "T1", "T2-partial");
    reg = plugins.reg;
    bridge = plugins.bridge;
    assert reg is not None;
    assert bridge is not None;
    entry = get_tool(reg as ToolRegistry, "echo");
    assert entry is not None;
    result = invoke(reg as ToolRegistry, "echo", {"text": "sess"}, bridge as PluginBridge);
    assert result == "ECHO:sess";
    session_dispose();
}


test "unsupported requires fail loud at load" {
    session_dispose();
    stub = resolve_stub_echo();
    st = session_boot(
        "t-unsup",
        os.getcwd(),
        [{
            "id": "stub.echo",
            "path": stub,
            "runtime": "node",
            "requires": ["renderers"],
        }],
        wait_budget_s=10.0,
    );
    ready = wait_extensions_ready(10.0);
    assert ready.phase == "degraded";
    assert "unsupported" in ready.detail or "renderers" in ready.detail;
    session_dispose();
}


test "load_extension_decls reads .jackal/extensions.json" {
    tmp = str(tempfile.mkdtemp());
    try {
        jackal = os.path.join(tmp, ".jackal");
        os.makedirs(jackal);
        stub = resolve_stub_echo();
        path = os.path.join(jackal, "extensions.json");
        fh: any = open(path, "w");
        try {
            fh.write(
                '{"extensions":[{"id":"stub.echo","path":"'
                + stub
                + '","runtime":"node"}]}'
            );
        } finally {
            fh.close();
        }
        decls = load_extension_decls(tmp);
        assert len(decls) == 1;
        assert decls[0].id == "stub.echo";
        assert decls[0].runtime == "node";
    } finally {
        import shutil;
        shutil.rmtree(tmp, ignore_errors=True);
    }
}


test "enqueue_prompt queues while loading" {
    session_dispose();
    n = enqueue_prompt("hello");
    assert n == 1;
    drained = drain_prompt_queue();
    assert drained == ["hello"];
    assert drain_prompt_queue() == [];
}


# ===================== T2-partial: commands + hooks =====================

import from .plugin_bridge { resolve_stub_commands, register_fake_command, register_fake_listener }


test "session_boot mirrors extension commands and run_command round-trips" {
    session_dispose();
    stub = resolve_stub_commands();
    st = session_boot(
        "t-t2-cmd",
        os.getcwd(),
        [{"id": "stub.commands", "path": stub, "runtime": "node"}],
        wait_budget_s=10.0,
    );
    ready = wait_extensions_ready(10.0);
    assert ready.phase == "ready";
    cmds = list_commands();
    assert "upper" in cmds;
    assert cmds["upper"]["extension_id"] == "stub.commands";

    out = run_command("upper", "hello session");
    assert "UPPER:HELLO SESSION" in out;

    err = run_command("missing_cmd", "");
    assert err.startswith("ERROR:");

    session_dispose();
    assert list_commands() == {};
}


test "run_command without a bridge degrades gracefully" {
    session_dispose();
    st = session_boot("t-t2-nobridge", os.getcwd(), []);
    assert st.total == 0;
    out = run_command("upper", "x");
    assert out.startswith("ERROR:");
    session_dispose();
}


test "turn_start and turn_end hooks fire around a turn" {
    session_dispose();
    # No decls -> no Node -> no bridge -> hooks are skipped silently. Use the
    # fake host path instead: attach listeners to a manual bridge.
    st = session_boot("t-t2-hooks", os.getcwd(), []);
    b = plugins.bridge;
    if b is None {
        b = create_bridge("t-t2-hooks-fake");
        plugins.bridge = b;
        ensure_host(b);
    }
    seen: list[str] = [];

    def _on_start(data: dict, ctx: any) -> str {
        seen.append("start:" + str(data.get("message", "")));
        return "";
    }

    def _on_end(data: dict, ctx: any) -> str {
        seen.append("end:" + str(round(float(data.get("secs", 0.0)), 1)));
        return "";
    }

    register_fake_listener(b, "turn_start", _on_start);
    register_fake_listener(b, "turn_end", _on_end);

    # Drive the hook path directly (react_loop needs a live model endpoint).
    res = fire_hook(b, "turn_start", {"message": "hook-msg"});
    assert len(res) == 1 and res[0]["ok"] is True;
    res2 = fire_hook(b, "turn_end", {"secs": 0.4, "tools": 0});
    assert len(res2) == 1;
    assert seen == ["start:hook-msg", "end:0.4"];
    plugins.bridge = None;
    dispose_bridge(b);
    session_dispose();
}
