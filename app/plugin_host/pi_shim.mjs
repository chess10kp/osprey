/**
 * Thin Pi-shaped extension surface for the Jackal plugin host.
 *
 * Extensions export `default` or `activate(api)`. The api offers registerTool
 * with { name, description, parameters, handler }. No Pi AgentSession yet —
 * tools only for the D11/D13 spike.
 */

import { pathToFileURL } from "node:url";

export function createHostState() {
  return {
    tools: new Map(),
    extensions: new Map(),
    cancelled: new Set(),
  };
}

function makeApi(state, extensionId) {
  return {
    registerTool(def) {
      if (!def || typeof def.name !== "string" || !def.name) {
        throw new Error("registerTool requires a non-empty name");
      }
      if (typeof def.handler !== "function") {
        throw new Error(`registerTool(${def.name}): handler required`);
      }
      state.tools.set(def.name, {
        name: def.name,
        description: def.description ?? "",
        parameters: def.parameters ?? { type: "object", properties: {} },
        handler: def.handler,
        extensionId,
      });
      const list = state.extensions.get(extensionId) ?? [];
      if (!list.includes(def.name)) {
        list.push(def.name);
      }
      state.extensions.set(extensionId, list);
    },
  };
}

function toolSchemasFor(state, extensionId) {
  const names = state.extensions.get(extensionId) ?? [];
  return names.map((name) => {
    const t = state.tools.get(name);
    return {
      name: t.name,
      description: t.description,
      parameters: t.parameters,
    };
  });
}

export async function handleEnvelope(state, env) {
  const kind = env?.kind ?? "";
  const base = {
    version: env?.version ?? 1,
    session_id: env?.session_id ?? "",
    request_id: env?.request_id ?? "",
    turn_id: env?.turn_id ?? "",
    tool_id: env?.tool_id ?? "",
    sequence: env?.sequence ?? 0,
    correlation_id: env?.correlation_id ?? "",
  };

  if (kind === "ext_load") {
    const id = String(env.payload?.id ?? "");
    const path = String(env.payload?.path ?? "");
    if (!id || !path) {
      return [
        {
          ...base,
          kind: "ext_loaded",
          payload: { id, tools: [], error: "id and path required" },
        },
      ];
    }
    try {
      // Drop prior contribution if reloading the same id.
      const prior = state.extensions.get(id) ?? [];
      for (const name of prior) {
        state.tools.delete(name);
      }
      state.extensions.delete(id);

      const href = pathToFileURL(path).href;
      const mod = await import(href);
      const activate = mod.default ?? mod.activate;
      if (typeof activate !== "function") {
        throw new Error("extension must export default or activate(api)");
      }
      await activate(makeApi(state, id));
      return [
        {
          ...base,
          kind: "ext_loaded",
          payload: { id, tools: toolSchemasFor(state, id) },
        },
      ];
    } catch (err) {
      return [
        {
          ...base,
          kind: "ext_loaded",
          payload: {
            id,
            tools: [],
            error: err instanceof Error ? err.message : String(err),
          },
        },
      ];
    }
  }

  if (kind === "ext_unload") {
    const id = String(env.payload?.id ?? "");
    const names = state.extensions.get(id) ?? [];
    for (const name of names) {
      state.tools.delete(name);
    }
    state.extensions.delete(id);
    return [];
  }

  if (kind === "tool_invoke") {
    const name = String(env.payload?.name ?? env.tool_id ?? "");
    const args = env.payload?.args ?? {};
    const corr = base.correlation_id;
    if (corr && state.cancelled.has(corr)) {
      state.cancelled.delete(corr);
      return [
        {
          ...base,
          kind: "tool_result",
          tool_id: name,
          payload: { ok: false, error: "cancelled" },
        },
      ];
    }
    const tool = state.tools.get(name);
    if (!tool) {
      return [
        {
          ...base,
          kind: "tool_result",
          tool_id: name,
          payload: { ok: false, error: `unknown tool ${name}` },
        },
      ];
    }
    try {
      const result = await tool.handler(args);
      return [
        {
          ...base,
          kind: "tool_result",
          tool_id: name,
          payload: { ok: true, result: String(result) },
        },
      ];
    } catch (err) {
      return [
        {
          ...base,
          kind: "tool_result",
          tool_id: name,
          payload: {
            ok: false,
            error: err instanceof Error ? err.message : String(err),
          },
        },
      ];
    }
  }

  if (kind === "tool_cancel") {
    const corr = base.correlation_id;
    if (corr) {
      state.cancelled.add(corr);
    }
    return [];
  }

  if (kind === "host_goodbye") {
    return [
      {
        ...base,
        kind: "host_goodbye",
        payload: { reason: env.payload?.reason ?? "peer" },
      },
    ];
  }

  return [
    {
      ...base,
      kind: "host_status",
      payload: { phase: "degraded", detail: `unknown kind ${kind}` },
    },
  ];
}
