"""Keybinding probe annex base.

IMPORT CONSTRAINT: tui.jac itself cannot be imported by tests - its
`with entry` block raises SystemExit(1) unless stdin AND stdout are TTYs,
and `jac test` runs headless. So this probe REPLICATES the tui._handle_key
precedence guard verbatim as probe_handle_key below (branch order and
expressions copied from app/tui.jac; keep in sync), and drives the
REPLICATED guard against the REAL agent.session shortcut seam:
list_extension_shortcuts + run_extension_shortcut over a fake plugin host
bridge. Tested for real: shortcut registration metadata, listing
filtering, shortcut invocation, result/notification plumbing. Only
replicated (not exercised): the branch ordering inside tui._handle_key.
"""

import from agent.session {
    plugins,
    list_extension_shortcuts,
    run_extension_shortcut,
}
import from agent.plugin_bridge {
    create_bridge,
    register_fake_shortcut,
    dispose_bridge,
}


"""Minimal LiveShell-shaped target. Only attributes read by the replicated
branches are present."""
obj KeyProbeShell {
    has running: bool = True,
        dirty: bool = False,
        phase: str = "ready",
        status_hint: str = "",
        ui_modal: any = None,
        approval: any = None,
        tool_replies: list = [];
}


"""Replica of the tui._handle_key precedence guard, trimmed to the branches
under test (extension-UI modal shares the overlay-node shape; heavier
enter/backspace/ctrl+u/ctrl+d tails need a live session and are omitted).

Guard order asserted by the tests:
  ctrl+c > extension-UI modal > pending approval > extension shortcuts
  (shadow built-in navigation) > escape (streaming abort vs idle quit).
"""
def probe_handle_key(app: KeyProbeShell, key: str) {
    if key == "ctrl+c" {
        app.running = False;
        return;
    }
    if app.ui_modal is not None {
        app.ui_modal = key;  # record: modal swallowed the keypress
        return;
    }
    if app.approval is not None {
        if key in ["a", "y", "enter"] or key in ["r", "n", "escape"] {
            return;
        }
        return;
    }
    scs = list_extension_shortcuts();
    if key in scs {
        meta: dict = scs[key];
        desc = str(meta.get("description", "") or "");
        app.status_hint = "shortcut " + key + (" — " + desc if desc else "");
        reply = run_extension_shortcut(key);
        if reply {
            app.tool_replies.append(reply);
        }
        app.dirty = True;
        return;
    }
    if key == "escape" {
        if app.phase == "streaming" {
            app.status_hint = "aborting…";
            app.dirty = True;
            return;
        }
        app.running = False;
        return;
    }
}


"""Build a probe shell wired to a fake plugin host bridge with shortcuts
registered for each (key, handler_result) pair. Returns (app, bridge, fired)
where `fired` records invoked keys. Caller MUST reset plugins.bridge and
dispose the bridge in a finally block."""
def make_key_probe(bindings: list[tuple]) -> tuple {
    fired: list = [];

    def _make_handler(result: str) -> any {
        def _handler(ctx: any) -> any {
            fired.append("hit");
            return result;
        }
        return _handler;
    }

    bridge = create_bridge("s-keybinding-probe");
    for binding in bindings {
        key: str = binding[0];
        result: str = binding[1];
        register_fake_shortcut(
            bridge, key, _make_handler(result),
            description="Probe " + key,
        );
    }
    plugins.bridge = bridge;
    return (KeyProbeShell(), bridge, fired);
}


"""Teardown helper shared by the tests."""
def drop_key_probe(bridge: any) {
    plugins.bridge = None;
    dispose_bridge(bridge);
}
