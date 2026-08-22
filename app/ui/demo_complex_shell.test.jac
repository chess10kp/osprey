"""Acceptance tests for the complex OSP UI shell demo."""


test "complex shell demo passes all validation steps" {
    demo = run_complex_shell_demo(columns=80, rows=24, verbose=False);
    assert demo.passed == True;
    assert demo.frames_rendered >= 3;
    assert demo.coalesced_deltas >= 4;
    assert demo.stable_ids == True;
    assert demo.disposed_clean == True;
    assert demo.invariant_findings == 0;
    assert len(demo.steps) >= 10;
    for step in demo.steps {
        assert step.ok == True;
    }
}


test "complex shell demo report is printable" {
    demo = run_complex_shell_demo(columns=60, rows=20, verbose=False);
    text = format_demo_report(demo);
    assert "OSP UI complex shell demo" in text;
    assert "PASS" in text or "FAIL" in text;
    assert "[ok]" in text or "[FAIL]" in text;
}
