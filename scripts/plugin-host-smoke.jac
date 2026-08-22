"""Headless Node plugin-host smoke (D11/D13/D21).

Measures both clocks, boots a session-owned sidecar from decls, invokes
stub_echo + pi_greet, then disposes.

Run from app/:
  cd app && jac run ../scripts/plugin-host-smoke.jac
"""

import os;
import sys;
import time;

import from agent.session {
    session_boot,
    session_dispose,
    wait_extensions_ready,
    extensions_status,
    run_command,
    plugins,
}
import from agent.plugin_bridge {
    resolve_stub_echo,
    resolve_pi_greet,
    resolve_stub_commands,
    resolve_node_bin,
    PluginBridge,
    fire_hook,
}
import from agent.registry { invoke, get_tool, ToolRegistry }


with entry {
    t_wall0 = time.time();
    stub = resolve_stub_echo();
    greet = resolve_pi_greet();
    cmds = resolve_stub_commands();
    node_bin = resolve_node_bin();
    print(f"node_bin={node_bin}");
    print("session_boot (parallel sidecar)…");
    st0 = session_boot(
        "smoke",
        os.getcwd(),
        [
            {"id": "stub.echo", "path": stub, "runtime": "node"},
            {"id": "pi.greet", "path": greet, "runtime": "node"},
            {"id": "stub.commands", "path": cmds, "runtime": "node"},
        ],
        wait_budget_s=15.0,
    );
    t_interactive = st0.t_interactive_s;
    print(f"  time_to_interactive={t_interactive - t_wall0:.3f}s label={st0.label}");
    ready = wait_extensions_ready(15.0);
    print(
        f"  time_to_extension_ready={ready.t_ext_ready_s - t_wall0:.3f}s "
        + f"label={ready.label} compat={ready.compat_tier}"
    );
    if ready.phase == "degraded" and ready.loaded < ready.total {
        print(f"FAIL: degraded {ready.detail}");
        session_dispose();
        sys.exit(1);
    }
    if ready.loaded != 3 {
        print(f"FAIL: expected 3 extensions loaded, got {ready.loaded}");
        session_dispose();
        sys.exit(1);
    }
    bridge = plugins.bridge;
    reg = plugins.reg;
    if bridge is None or reg is None {
        print("FAIL: missing session bridge/registry");
        session_dispose();
        sys.exit(1);
    }
    echo = get_tool(reg as ToolRegistry, "echo");
    if echo is None or echo.origin != "js" {
        print("FAIL: echo not registered as js");
        session_dispose();
        sys.exit(1);
    }
    result = invoke(reg as ToolRegistry, "echo", {"text": "smoke"}, bridge as PluginBridge);
    print(f"  echo -> {result}");
    if result != "ECHO:smoke" {
        print("FAIL: unexpected echo result");
        session_dispose();
        sys.exit(1);
    }
    gresult = invoke(reg as ToolRegistry, "greet", {"name": "smoke"}, bridge as PluginBridge);
    print(f"  greet -> {gresult}");
    if gresult != "Hello, smoke!" {
        print("FAIL: unexpected greet result");
        session_dispose();
        sys.exit(1);
    }
    # T2-partial: commands + lifecycle hooks through the same bridge.
    cmd_out = run_command("upper", "smoke t2");
    print(f"  /upper -> {cmd_out.replace(chr(10), ' | ')}");
    if "UPPER:SMOKE T2" not in cmd_out {
        print("FAIL: command round-trip failed");
        session_dispose();
        sys.exit(1);
    }
    hooks = fire_hook(bridge as PluginBridge, "turn_start", {"message": "smoke"});
    if not hooks or not hooks[0].get("ok") {
        print(f"FAIL: hook_fire failed: {hooks}");
        session_dispose();
        sys.exit(1);
    }
    print(f"  turn_start hook -> {hooks[0].get('result', '')}");
    session_dispose();
    print("dispose ok");
    print("plugin-host-smoke: PASS");
}
