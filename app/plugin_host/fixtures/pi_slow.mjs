/**
 * Slow tool that honors AbortSignal — used for cancel / concurrent tests.
 */
export default function (pi) {
  pi.registerTool({
    name: "slow_echo",
    description: "echo after delay; abortable",
    parameters: {
      type: "object",
      properties: {
        text: { type: "string" },
        ms: { type: "number" },
      },
      required: ["text"],
    },
    async execute(_toolCallId, params, signal) {
      const ms = Number(params.ms ?? 200);
      const text = String(params.text ?? "");
      await new Promise((resolve, reject) => {
        const t = setTimeout(resolve, ms);
        if (signal) {
          const onAbort = () => {
            clearTimeout(t);
            const err = new Error("aborted");
            err.name = "AbortError";
            reject(err);
          };
          if (signal.aborted) {
            onAbort();
            return;
          }
          signal.addEventListener("abort", onAbort, { once: true });
        }
      });
      return `SLOW:${text}`;
    },
  });
}
