/**
 * Pi-shaped fixture exercising the keyboard-shortcut binding path over the
 * real Node host:
 * - registers a ctrl+alt+T shortcut whose handler notifies and returns text;
 * - `fire_shortcut` tool invokes it via api-level state so the Jac-side test
 *   can assert the full shortcut_invoke -> handler -> shortcut_result loop.
 */

export default function activate(api) {
  api.registerShortcut("ctrl+alt+t", {
    description: "Probe shortcut: notify + return",
    handler: async (ctx) => {
      ctx.ui.notify("shortcut-fired");
      return "probe-ok";
    },
  });
}
