"""Smoke probe: frozen legacy oracle module imports cleanly from ui tests."""

import from ui.testing.legacy_layout_oracle {
    legacy_measure_and_arrange,
}

test "oracle module imports" {
    assert True;
}
