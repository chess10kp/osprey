/**
 * Real Pi-shaped extension fixture (not the Jackal handler() stub).
 *
 * Mirrors pi-coding-agent docs: default export receives `pi`, registers a
 * tool with `execute(toolCallId, params)` returning AgentToolResult.
 */

export default function (pi) {
  pi.registerTool({
    name: "greet",
    label: "Greet",
    description: "Greet someone by name (Pi execute() shape)",
    parameters: {
      type: "object",
      properties: {
        name: { type: "string", description: "Name to greet" },
      },
      required: ["name"],
    },
    async execute(_toolCallId, params) {
      const who = params?.name ?? "world";
      return {
        content: [{ type: "text", text: `Hello, ${who}!` }],
        details: { greeted: who },
      };
    },
  });

  // Exercise no-op stubs so load does not fail on common Pi APIs.
  pi.on("session_start", async () => {});
  pi.registerCommand("greet-cmd", {
    description: "noop",
    handler: async () => {},
  });
}
