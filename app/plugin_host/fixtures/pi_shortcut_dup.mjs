/**
 * Fixture: registers a shortcut key that another fixture already owns
 * (pair with pi_shortcut_probe.mjs's binding, or load twice). Exercising
 * this via ext_load must emit a duplicate-shortcut console.warn while the
 * extension still loads — dispatch stays first-wins (shortcut_invoke .find).
 */
export default function activate(pi) {
  pi.registerShortcut("ctrl+shift+g", {
    description: "duplicate-key probe",
    handler() {},
  });
}
