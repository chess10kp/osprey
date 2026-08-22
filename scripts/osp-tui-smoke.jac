"""Retired legacy smoke: OSP flat-diff TUI path (pre Unit 6 retained renderer).

Use virtual-terminal renderer tests instead:
  cd app && JAC_TEST_JOBS=0 jac test ui/renderer.test.jac
"""

with entry {
    print("osp-tui-smoke: retired — see app/ui/renderer.test.jac");
}
