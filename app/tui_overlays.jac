"""Anchor module for tui_overlays.test.jac.

Jac test files are annexes of a base module, so this companion file must
exist for `jac test tui_overlays.test.jac` to import. The tested logic is
the verbatim replica (see the test file's docstring) of tui.jac's pure
tasks/checkpoints picker-entry builders; tui.jac itself cannot be imported
headless because of its `with entry` TTY guard.
"""
