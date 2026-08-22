"""Session plugin boot + dual clocks + bridge wiring (P1/P2)."""

import os;
import time;
import tempfile;

import from .plugin_bridge { resolve_stub_echo, resolve_pi_greet, PluginBridge }
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
    assert plugins.bridge.compat_tier in ("T0", "T1");
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
            "requires": ["commands"],
        }],
        wait_budget_s=10.0,
    );
    ready = wait_extensions_ready(10.0);
    assert ready.phase == "degraded";
    assert "unsupported" in ready.detail or "commands" in ready.detail;
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
