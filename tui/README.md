# tui/

The product TUI is the native Jac shell: `app/tui.jac` (run via `./jackal.sh`
or `cd app && jac run tui.jac`). This directory no longer hosts a renderer.

What remains here:

- `js2jac/` — active TS→Jac conversion workstream (see `js2jac/SYNC.md`)
- `pi_jac_PORT_STATUS.md` — historical port census
- `jackal-tui` — legacy launcher script (its TSX entry point was removed)
