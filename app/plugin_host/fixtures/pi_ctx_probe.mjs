/**
 * Pi-shaped fixture probing the tool execute() context:
 * - `probe_ctx` reports the ctx shape (cwd/ui presence) plus pi.getAllTools()
 *   output (builtin enrichment check).
 * - `probe_ui` exercises ctx.ui.notify + setStatus; their payloads must ride
 *   the tool_result reply as notifications / ui_events.
 */

export default function activate(api) {
  api.registerTool({
    name: "probe_ctx",
    description: "Report execute() ctx shape and getAllTools() names",
    parameters: { type: "object", properties: {} },
    execute: async (_toolCallId, _args, _signal, _onUpdate, ctx) => {
      const tools = api.getAllTools().map((t) => t.name);
      const withSource = api
        .getAllTools()
        .filter((t) => t.sourceInfo && typeof t.sourceInfo.path === "string");
      const probe = api.getAllTools().find((t) => t.name === "probe_ctx");
      return JSON.stringify({
        has_cwd: typeof ctx?.cwd === "string" && ctx.cwd.length > 0,
        ui_kind: typeof ctx?.ui,
        notify_kind: typeof ctx?.ui?.notify,
        select_kind: typeof ctx?.ui?.select,
        tools,
        source_info_count: withSource.length,
        probe_source: probe?.sourceInfo ?? null,
      });
    },
  });

  api.registerTool({
    name: "probe_ui",
    description: "Emit ui.notify and ui.setStatus from inside execute()",
    parameters: { type: "object", properties: {} },
    execute: async (_toolCallId, _args, _signal, _onUpdate, ctx) => {
      if (!ctx?.ui || typeof ctx.ui.notify !== "function") {
        throw new Error("ctx.ui.notify missing");
      }
      ctx.ui.notify("hello-from-tool");
      ctx.ui.setStatus("probe-busy");
      return "ui exercised";
    },
  });
}
