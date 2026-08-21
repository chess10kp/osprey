"""Headless Node plugin-host smoke (D11/D13).

Spawns app/plugin_host/host.mjs, loads fixtures/stub_echo.mjs, invokes echo,
then reaps the process. Not on Jackal's default startup path.

Run from repo root or app/:
  jac run scripts/plugin-host-smoke.jac
  cd app && jac run ../scripts/plugin-host-smoke.jac
"""

import os;
import sys;

import from agent.plugin_bridge {
    create_bridge,
    ensure_node_host,
    load_extension_path,
    dispose_bridge,
    resolve_stub_echo,
    drain_inbox,
}
import from agent.registry {
    create_registry,
    get_tool,
    invoke,
}


with entry {
    bridge = create_bridge("smoke");
    reg = create_registry();
    print("ensure_node_host…");
    phase = ensure_node_host(bridge);
    print(f"  phase={phase} kind={bridge.host_kind}");
    kinds = drain_inbox(bridge);
    print(f"  inbox={kinds}");
    if "host_hello" not in kinds {
        print("FAIL: missing host_hello");
        sys.exit(1);
    }
    stub = resolve_stub_echo();
    print(f"load_extension_path {stub}");
    names = load_extension_path(bridge, reg, "stub.echo", stub);
    print(f"  tools={names}");
    entry = get_tool(reg, "echo");
    if entry is None or entry.origin != "js" {
        print("FAIL: echo not registered as js");
        dispose_bridge(bridge);
        sys.exit(1);
    }
    result = invoke(reg, "echo", {"text": "smoke"}, bridge);
    print(f"  invoke -> {result}");
    if result != "ECHO:smoke" {
        print("FAIL: unexpected echo result");
        dispose_bridge(bridge);
        sys.exit(1);
    }
    dispose_bridge(bridge);
    print("dispose ok");
    print("plugin-host-smoke: PASS");
}
