/**
 * Minimal Pi-shaped extension fixture: one echo tool.
 * Loaded by the plugin host via ext_load { path }.
 */

export default function activate(api) {
  api.registerTool({
    name: "echo",
    description: "Echo text back (JS host fixture)",
    parameters: {
      type: "object",
      properties: {
        text: { type: "string", description: "Text to echo" },
      },
      required: ["text"],
    },
    handler: async (args) => {
      const text = args?.text ?? "";
      return `ECHO:${text}`;
    },
  });
}
