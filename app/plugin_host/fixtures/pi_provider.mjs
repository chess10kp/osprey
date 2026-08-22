/**
 * P10 provider fixture: declares a custom provider with one model.
 * Pair with pi_gated.mjs semantics — activate-time registration only;
 * request mutation rides the separate before_provider_request hook.
 */
export default function activate(pi) {
  pi.registerProvider({
    name: "acme",
    models: ["sonnet-x", { id: "opus-y", name: "Opus Y" }],
    streaming: true,
  });
}
