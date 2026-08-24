"""Tests for cheap lifecycle events (user_bash, project_trust) — annex of
agent/plugin_hooks_events.jac.

Proves the arbitrary-name hook_fire pass-through end-to-end: fake-host
dispatch, real Node sidecar round-trip via
plugin_host/fixtures/pi_lifecycle_probe.mjs, and the name-pinned helpers.
"""


test "fire_user_bash reaches fake-host listeners" {
    bridge = create_bridge("s-ub-fake");
    seen: dict = {};
    def grab(data: dict, ctx: any) -> str {
        seen["command"] = str(data.get("command", ""));
        return "bash-seen";
    }
    register_fake_listener(bridge, "user_bash", grab);
    results = fire_user_bash(bridge, "npm test");
    assert len(results) == 1;
    assert bool(results[0].get("ok")) is True;
    assert results[0].get("result") == "bash-seen";
    assert seen.get("command") == "npm test";
    dispose_bridge(bridge);
}


test "fire_project_trust reaches fake-host listeners" {
    bridge = create_bridge("s-pt-fake");
    seen2: dict = {};
    def grab2(data: dict, ctx: any) -> str {
        seen2["path"] = str(data.get("path", ""));
        return "trust-seen";
    }
    register_fake_listener(bridge, "project_trust", grab2);
    results2 = fire_project_trust(bridge, "/tmp/demo");
    assert len(results2) == 1;
    assert bool(results2[0].get("ok")) is True;
    assert seen2.get("path") == "/tmp/demo";
    dispose_bridge(bridge);
}


test "lifecycle events round-trip through the real node host" {
    bridge3 = create_bridge("s-lifecycle-node");
    reg = create_registry();
    phase = ensure_node_host(bridge3);
    assert phase == "ready";
    assert bridge3.host_kind == "node";
    fixture = os.path.join(
        os.getcwd(), "plugin_host", "fixtures", "pi_lifecycle_probe.mjs"
    );
    names = load_extension_path(bridge3, reg, "pi.probe", fixture);
    assert len(names) == 0;

    ub = fire_hook(bridge3, "user_bash", {"command": "echo hi"});
    assert len(ub) == 1;
    assert bool(ub[0].get("ok")) is True;
    res_ub = str(ub[0].get("result", ""));
    assert "user_bash:" in res_ub;
    assert "echo hi" in res_ub;

    pt = fire_hook(bridge3, "project_trust", {"path": "/tmp/demo"});
    assert len(pt) == 1;
    assert "project_trust:" in str(pt[0].get("result", ""));

    # Name-pinned helpers ride the same wire.
    via_helper = fire_user_bash(bridge3, "jac test", "ok 42");
    assert len(via_helper) == 1;
    res_h = str(via_helper[0].get("result", ""));
    assert "jac test" in res_h and "42" in res_h;

    dispose_bridge(bridge3);
}


test "unknown lifecycle event names return empty results, never raise" {
    bridge4 = create_bridge("s-unknown-fake");
    out = fire_hook(bridge4, "session_before_switch", {"from": "a", "to": "b"});
    assert out == [];
    out2 = fire_hook(bridge4, "session_info_changed", {});
    assert out2 == [];
    dispose_bridge(bridge4);
}
