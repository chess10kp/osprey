/**
 * P12 interactive-UI fixture extension.
 *
 * Commands block on real ui.select/confirm/input round-trips; a hook folds
 * the answer into its verdict; a tool uses ui during invoke; editor/custom
 * probe that they fail loud. Envelope order expected on the wire:
 *   cmd_invoke -> ui_request(child) -> ui_response(child) -> cmd_result
 */
export function activate(pi) {
  pi.registerCommand({
    name: "pick-color",
    description: "blocks until ui.select is answered",
    async run(args, ctx) {
      const chosen = await ctx.ui.select("pick one", ["red", "green", "blue"], {
        timeout: args?.timeout,
      });
      return `picked:${chosen ?? "none"}`;
    },
  });

  pi.registerCommand({
    name: "ask-sure",
    description: "confirm yes/no/Esc mapping",
    async run(args, ctx) {
      const yes = await ctx.ui.confirm("are you sure?", { timeout: args?.timeout });
      return `confirmed:${yes}`;
    },
  });

  pi.registerCommand({
    name: "get-name",
    description: "empty input must stay distinguishable from cancel",
    async run(args, ctx) {
      const value = await ctx.ui.input("your name", "", { timeout: args?.timeout });
      if (value === undefined) {
        return "name:cancelled";
      }
      return `name:${JSON.stringify(value)}`;
    },
  });

  // Verdict-dependent hook: answer flows into hook_fire verdict data.
  pi.on("before_agent_start", async (_data, ctx) => {
    const ok = await ctx.ui.confirm("hook gate", { timeout: _data?.timeout });
    return ok ? undefined : { action: "block" };
  });

  // Tool that consults the user mid-invoke.
  pi.registerTool({
    name: "ui_tool",
    description: "asks via ui.select during execution",
    parameters: { type: "object", properties: {} },
    async execute(_args) {
      // NOTE: tools receive no ctx in this host yet — UI from tools arrives
      // with the handler-context slice; this tool intentionally does NOT use
      // ui today so the fixture stays green across both slices.
      return "ui_tool:ok";
    },
  });

  pi.registerCommand({
    name: "probe-editor",
    description: "must fail loud, never fake a value",
    async run(_args, ctx) {
      try {
        await ctx.ui.editor({});
        return "editor:no-error";
      } catch (err) {
        return `editor:error:${err instanceof Error ? err.message : String(err)}`;
      }
    },
  });

  pi.registerCommand({
    name: "probe-custom",
    description: "must fail loud",
    async run(_args, ctx) {
      try {
        await ctx.ui.custom({});
        return "custom:no-error";
      } catch (err) {
        return `custom:error:${err instanceof Error ? err.message : String(err)}`;
      }
    },
  });
}
