/**
 * P11 renderer fixture: message + entry renderers returning plain data that
 * normalizes to native content lines (app/ui set_node_content currency).
 */
export default function activate(pi) {
  pi.registerMessageRenderer("assistant", (message) => {
    const text = typeof message === "string" ? message : String(message?.content ?? "");
    return { lines: ["[acme] " + text] };
  });

  pi.registerEntryRenderer("usage", (data) => {
    const d = data && typeof data === "object" ? data : {};
    return ["tokens: " + String(d.tokens ?? 0), "cost: $" + String(d.cost ?? "0.00")];
  });
}
