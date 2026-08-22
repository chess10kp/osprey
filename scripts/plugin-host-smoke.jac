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
    plugins,
}
import from agent.plugin_bridge {
    resolve_stub_echo,
    resolve_pi_greet,
    resolve_node_bin,
    PluginBridge,
}
import from agent.registry { invoke, get_tool, ToolRegistry }


with entry {
    t_wall0 = time.time();
    stub = resolve_stub_echo();
    greet = resolve_pi_greet();
    node_bin = resolve_node_bin();
    print(f"node_bin={node_bin}");
    print("session_boot (parallel sidecar)…");
    st0 = session_boot(
        "smoke",
        os.getcwd(),
        [
            {"id": "stub.echo", "path": stub, "runtime": "node"},
            {"id": "pi.greet", "path": greet, "runtime": "node"},
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
    if ready.loaded != 2 {
        print(f"FAIL: expected 2 extensions loaded, got {ready.loaded}");
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
    session_dispose();
    print("dispose ok");
    print("plugin-host-smoke: PASS");
}
