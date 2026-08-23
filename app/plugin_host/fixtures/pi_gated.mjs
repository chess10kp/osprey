/**
 * Batch-2 event fixture: exercises structured hook verdicts.
 *
 * - tool_call: blocks bash commands containing "rm -rf" ({block, reason,
 *   terminate}) and mutates echo_arg input in place (uppercases `text`).
 * - input: handles "!gate" outright, transforms "?upper <rest>".
 * - context: appends an injection marker message (in-place edit).
 * - before_agent_start: appends to the system prompt.
 */
export default function activate(pi) {
  pi.registerTool({
    name: "noop",
    description: "no-op tool for gating tests",
    parameters: { type: "object", properties: {} },
    execute: async () => "ok",
  });

  pi.on("tool_call", async (event) => {
    if (
      event.toolName === "bash" &&
      String(event.input?.command ?? "").includes("rm -rf")
    ) {
      return { block: true, reason: "dangerous command", terminate: true };
    }
    if (event.toolName === "echo_arg" && event.input && typeof event.input.text === "string") {
      event.input.text = event.input.text.toUpperCase();
    }
    return undefined;
  });

  pi.on("input", async (event) => {
    if (event.text === "!gate") {
      return { action: "handled" };
    }
    if (typeof event.text === "string" && event.text.startsWith("?upper ")) {
      return { action: "transform", text: event.text.slice(7).toUpperCase() };
    }
    return undefined;
  });

  // Second input handler proving transforms CHAIN: this must see the
  // rewritten text from the handler above, not the original.
  pi.on("input", async (event) => {
    const t = String(event.text ?? "");
    if (t && t === t.toUpperCase() && /[A-Z]/.test(t)) {
      return { action: "transform", text: t + "-CHAINED" };
    }
    return undefined;
  });

  // tool_result middleware: appends a marker line to every successful
  // echo_arg result (chaining pin for the node path).
  pi.on("tool_result", async (event) => {
    if (
      event.toolName === "echo_arg" &&
      !event.isError &&
      typeof event.content === "string"
    ) {
      return { content: event.content + "\n[gated-result-marker]" };
    }
    return undefined;
  });

  pi.on("context", async (event) => {
    if (Array.isArray(event.messages)) {
      event.messages.push({ role: "user", content: "[gated-context-injection]" });
    }
    return undefined;
  });

  pi.on("before_agent_start", async () => {
    return { systemPrompt: "\n[gated-system-append]" };
  });
}
