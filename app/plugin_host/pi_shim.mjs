/**
 * Pi-compatible extension surface for the Jackal plugin host (D11/D13/D21).
 *
 * Real Pi extensions export `default function (pi) { ... }` and call
 * `pi.registerTool({ name, label?, description, parameters, execute })`.
 * `execute(toolCallId, params, signal?, onUpdate?, ctx?)` returns either a
 * string or `{ content: [{ type: "text", text }], details? }`.
 *
 * Jackal also accepts the spike shape `{ handler(args) }` so fixtures keep
 * working.
 *
 * Compat honesty (P4): this host ships **T0/T1 tool-extension compatibility**.
 * Commands, events, renderers, and session hooks are stubs. If an extension
 * declares `requires` for those surfaces, load fails loud — never silent
 * success with dead stubs.
 */

import { pathToFileURL } from "node:url";

/** Advertised capabilities — grow this list when real support lands. */
export const HOST_CAPS = ["tools", "cancel", "updates"];
export const COMPAT_TIER = "T1";

/** Surfaces that remain stubs today (not in HOST_CAPS). */
const STUB_CAPS = new Set([
  "commands",
  "events",
  "renderers",
  "transformers",
  "session_hooks",
]);

export function createHostState() {
  return {
    tools: new Map(),
    extensions: new Map(),
    cancelled: new Set(),
  };
}

/** Normalize TypeBox-ish or JSON-schema parameters to plain JSON schema. */
function normalizeParameters(parameters) {
  if (parameters == null) {
    return { type: "object", properties: {} };
  }
  if (typeof parameters === "object") {
    if (typeof parameters.toJSON === "function") {
      try {
        return parameters.toJSON();
      } catch {
        /* fall through */
      }
    }
    if (parameters.type || parameters.properties || parameters.$schema) {
      return parameters;
    }
  }
  return { type: "object", properties: {} };
}

function resultToString(result) {
  if (result == null) {
    return "";
  }
  if (typeof result === "string") {
    return result;
  }
  if (typeof result === "object" && Array.isArray(result.content)) {
    const texts = [];
    for (const part of result.content) {
      if (part && part.type === "text" && part.text != null) {
        texts.push(String(part.text));
      } else if (typeof part === "string") {
        texts.push(part);
      }
    }
    return texts.join("\n");
  }
  return String(result);
}

function makePiApi(state, extensionId) {
  const api = {
    registerTool(def) {
      if (!def || typeof def.name !== "string" || !def.name) {
        throw new Error("registerTool requires a non-empty name");
      }
      const execute = def.execute;
      const handler = def.handler;
      if (typeof execute !== "function" && typeof handler !== "function") {
        throw new Error(
          `registerTool(${def.name}): execute or handler required`,
        );
      }
      const run = async (args, toolCallId = "call", signal, onUpdate) => {
        if (typeof execute === "function") {
          const out = await execute(toolCallId, args, signal, onUpdate, {
            cwd: process.cwd(),
          });
          return resultToString(out);
        }
        return resultToString(await handler(args));
      };
      state.tools.set(def.name, {
        name: def.name,
        label: def.label ?? def.name,
        description: def.description ?? "",
        parameters: normalizeParameters(def.parameters),
        run,
        extensionId,
      });
      const list = state.extensions.get(extensionId) ?? [];
      if (!list.includes(def.name)) {
        list.push(def.name);
      }
      state.extensions.set(extensionId, list);
    },

    // ---- stubs so real Pi extensions do not crash on load ----
    // If declared in requires[], load fails before activate (see handleEnvelope).
    on(_event, _handler) {
      return api;
    },
    registerCommand(_name, _def) {
      /* no-op — T2 not advertised */
    },
    registerMessageRenderer(_type, _renderer) {
      /* no-op */
    },
    registerMessageTransformer(_fn) {
      /* no-op */
    },
    sendMessage(_msg) {
      /* no-op */
    },
    appendEntry(_type, _data) {
      /* no-op */
    },
    setActiveTools(_names) {
      /* no-op */
    },
    getActiveTools() {
      return [...state.tools.keys()];
    },
    getAllTools() {
      return [...state.tools.values()].map((t) => ({
        name: t.name,
        description: t.description,
        parameters: t.parameters,
      }));
    },
  };
  return api;
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

function unsupportedRequires(requires) {
  const missing = [];
  for (const r of requires || []) {
    const need = String(r);
    if (!need) continue;
    if (!HOST_CAPS.includes(need) || STUB_CAPS.has(need)) {
      if (!HOST_CAPS.includes(need)) {
        missing.push(need);
      }
    }
  }
  return missing;
}

/**
 * @param {ReturnType<typeof createHostState>} state
 * @param {object} env
 * @param {{ signal?: AbortSignal, onUpdate?: Function }} [ctx]
 */
export async function handleEnvelope(state, env, ctx = {}) {
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
    const requires = Array.isArray(env.payload?.requires)
      ? env.payload.requires
      : [];
    if (!id || !path) {
      return [
        {
          ...base,
          kind: "ext_loaded",
          payload: { id, tools: [], error: "id and path required" },
        },
      ];
    }
    const missing = unsupportedRequires(requires);
    if (missing.length) {
      return [
        {
          ...base,
          kind: "ext_loaded",
          payload: {
            id,
            tools: [],
            error: `unsupported requirements: ${missing.join(", ")}`,
            unsupported: missing,
            compat: COMPAT_TIER,
            caps: HOST_CAPS,
          },
        },
      ];
    }
    try {
      const prior = state.extensions.get(id) ?? [];
      for (const name of prior) {
        state.tools.delete(name);
      }
      state.extensions.delete(id);

      const href = pathToFileURL(path).href;
      const mod = await import(`${href}?t=${Date.now()}`);
      const activate = mod.default ?? mod.activate;
      if (typeof activate !== "function") {
        throw new Error("extension must export default or activate(pi)");
      }
      await activate(makePiApi(state, id));
      return [
        {
          ...base,
          kind: "ext_loaded",
          payload: {
            id,
            tools: toolSchemasFor(state, id),
            compat: COMPAT_TIER,
            caps: HOST_CAPS,
          },
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
    const signal = ctx.signal;
    const onUpdate = typeof ctx.onUpdate === "function" ? ctx.onUpdate : undefined;

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
    if (signal?.aborted) {
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
      const result = await tool.run(args, corr || "call", signal, onUpdate);
      if (signal?.aborted || (corr && state.cancelled.has(corr))) {
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
      return [
        {
          ...base,
          kind: "tool_result",
          tool_id: name,
          payload: { ok: true, result: String(result) },
        },
      ];
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      const cancelled =
        signal?.aborted ||
        (corr && state.cancelled.has(corr)) ||
        (err && err.name === "AbortError");
      if (corr) state.cancelled.delete(corr);
      return [
        {
          ...base,
          kind: "tool_result",
          tool_id: name,
          payload: { ok: false, error: cancelled ? "cancelled" : msg },
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
