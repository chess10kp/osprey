/**
 * T2-partial fixture: registers a command and a lifecycle hook.
 *
 * - Command "upper": uppercases its args string, reports via ctx.ui.notify,
 *   and returns the transformed text as the command result.
 * - Hook "turn_start": returns "ts:<message>" so callers can observe that
 *   hook dispatch round-trips.
 */

const seen = [];

export default function (pi) {
  pi.registerCommand("upper", {
    description: "Uppercase the given args",
    handler: async (args, ctx) => {
      const out = String(args ?? "").trim().toUpperCase();
      ctx.ui.notify(`UPPER:${out}`);
      return out;
    },
  });

  pi.on("turn_start", async (event, _ctx) => {
    seen.push(event);
    return "ts:" + String(event?.message ?? "");
  });

  // T2b: display-only markdown transformer — wraps fenced code blocks.
  pi.registerMarkdownTransformer((markdown, _ctx) => {
    return String(markdown ?? "").replaceAll("```", "≡≡≡");
  });
}

/** Test introspection. */
export function __seen() {
  return seen;
}
