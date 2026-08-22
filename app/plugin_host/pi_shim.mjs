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
 * Compat honesty (P4): this host ships **T2-partial** compatibility — tools
 * (T0/T1), commands, lifecycle session hooks, and markdown transformers are
 * real; UI events and renderers remain stubs. If an extension declares
 * `requires` for a stub surface, load fails loud — never silent success with
 * dead stubs.
 */

import { pathToFileURL } from "node:url";

/** Advertised capabilities — grow this list when real support lands. */
export const HOST_CAPS = [
  "tools",
  "cancel",
  "updates",
  "commands",
  "session_hooks",
  "transformers",
];
export const COMPAT_TIER = "T2-partial";

/** Surfaces that remain stubs today (not in HOST_CAPS). */
const STUB_CAPS = new Set(["events", "renderers"]);

export function createHostState() {
  return {
    tools: new Map(),
    commands: new Map(),
    listeners: new Map(),
    /** Ordered markdown transformers: [{ fn, extensionId }] in load order. */
    mdTransformers: [],
    extensions: new Map(),
    cancelled: new Set(),
  };
}

/** Minimal UI context handed to command/hook handlers. Notifications are
 * collected and shipped back over the wire — not silently dropped. */
function makeUi(state, extensionId) {
  const bucket = [];
  return {
    notifications: bucket,
    notify(message, _level) {
      bucket.push(String(message ?? ""));
    },
    setStatus(_owner, _text) {
      /* status line is a native-UI surface — accepted, not rendered */
    },
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

/** Remove every registration owned by an extension (tools, commands,
 * listeners). Ownership is tracked per extension so unload stays exact. */
function dropExtension(state, extensionId) {
  const owned = state.extensions.get(extensionId);
  if (!owned) {
    return;
  }
  for (const name of owned.tools) {
    state.tools.delete(name);
  }
  for (const name of owned.commands) {
    state.commands.delete(name);
  }
  for (const [event, list] of state.listeners) {
    state.listeners.set(
      event,
      list.filter((l) => l.extensionId !== extensionId),
    );
  }
  state.mdTransformers = state.mdTransformers.filter(
    (t) => t.extensionId !== extensionId,
  );
  state.extensions.delete(extensionId);
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
      if (!state.extensions.has(extensionId)) {
        state.extensions.set(extensionId, { tools: [], commands: [], hooks: 0 });
      }
      const owned = state.extensions.get(extensionId);
      if (!owned.tools.includes(def.name)) {
        owned.tools.push(def.name);
      }
    },

    registerCommand(name, def) {
      if (typeof name !== "string" || !name) {
        throw new Error("registerCommand requires a non-empty name");
      }
      if (!def || typeof def.handler !== "function") {
        throw new Error(`registerCommand(${name}): handler required`);
      }
      state.commands.set(name, {
        name,
        description: def.description ?? "",
        handler: def.handler,
        extensionId,
      });
      const owned = state.extensions.get(extensionId);
      if (owned && !owned.commands.includes(name)) {
        owned.commands.push(name);
      }
    },

    on(event, handler) {
      if (typeof event !== "string" || !event) {
        throw new Error("pi.on requires a non-empty event name");
      }
      if (typeof handler !== "function") {
        throw new Error(`pi.on(${event}): handler must be a function`);
      }
      if (!state.listeners.has(event)) {
        state.listeners.set(event, []);
      }
      state.listeners.get(event).push({ event, handler, extensionId });
      const owned = state.extensions.get(extensionId);
      if (owned) {
        owned.hooks += 1;
      }
      return api;
    },

    registerMarkdownTransformer(fn) {
      if (typeof fn !== "function") {
        throw new Error("registerMarkdownTransformer requires a function");
      }
      if (!state.extensions.has(extensionId)) {
        state.extensions.set(extensionId, {
          tools: [],
          commands: [],
          hooks: 0,
          transformers: 0,
        });
      }
      const owned = state.extensions.get(extensionId);
      owned.transformers = (owned.transformers ?? 0) + 1;
      state.mdTransformers.push({ fn, extensionId });
      return api;
    },

    // ---- stubs so real Pi extensions do not crash on load ----
    // If declared in requires[], load fails before activate (see handleEnvelope).
    registerMessageRenderer(_type, _renderer) {
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
  const names = state.extensions.get(extensionId)?.tools ?? [];
  return names.map((name) => {
    const t = state.tools.get(name);
    return {
      name: t.name,
      description: t.description,
      parameters: t.parameters,
    };
  });
}

function commandsFor(state, extensionId) {
  return (state.extensions.get(extensionId)?.commands ?? []).map((name) => {
    const c = state.commands.get(name);
    return { name: c.name, description: c.description };
  });
}

function unsupportedRequires(requires) {
  const missing = [];
  for (const r of requires || []) {
    const need = String(r);
    if (!need) continue;
    if (!HOST_CAPS.includes(need) || STUB_CAPS.has(need)) {
      missing.push(need);
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
      dropExtension(state, id);
      state.extensions.set(id, {
        tools: [],
        commands: [],
        hooks: 0,
        transformers: 0,
      });

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
            commands: commandsFor(state, id),
            transformers:
              state.extensions.get(id)?.transformers ?? 0,
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
    dropExtension(state, id);
    return [];
  }

  if (kind === "cmd_invoke") {
    const name = String(env.payload?.name ?? "");
    const args = env.payload?.args ?? "";
    const cmd = state.commands.get(name);
    if (!cmd) {
      return [
        {
          ...base,
          kind: "cmd_result",
          payload: { ok: false, error: `unknown command ${name}` },
        },
      ];
    }
    const ui = makeUi(state, cmd.extensionId);
    try {
      const result = await cmd.handler(args, { ui });
      return [
        {
          ...base,
          kind: "cmd_result",
          payload: {
            ok: true,
            result: result == null ? "" : String(result),
            notifications: ui.notifications,
          },
        },
      ];
    } catch (err) {
      return [
        {
          ...base,
          kind: "cmd_result",
          payload: {
            ok: false,
            error: err instanceof Error ? err.message : String(err),
            notifications: ui.notifications,
          },
        },
      ];
    }
  }

  if (kind === "md_transform") {
    // Display-only chain, run serially in extension load order. A throwing
    // transformer keeps the output produced so far (Pi semantics).
    let md = String(env.payload?.markdown ?? "");
    const mctx = {
      messageType: String(env.payload?.message_type ?? "assistant"),
      isStreaming: Boolean(env.payload?.streaming),
    };
    for (const t of state.mdTransformers) {
      try {
        const out = await t.fn(md, mctx);
        if (typeof out === "string") {
          md = out;
        }
      } catch {
        /* keep prior output, continue chain */
      }
    }
    return [{ ...base, kind: "md_transformed", payload: { markdown: md } }];
  }

  if (kind === "hook_fire") {
    const event = String(env.payload?.event ?? "");
    const data = env.payload?.data ?? {};
    const listeners = state.listeners.get(event) ?? [];
    const results = [];
    for (const listener of listeners) {
      const ui = makeUi(state, listener.extensionId);
      try {
        const out = await listener.handler(data, { ui });
        results.push({
          ok: true,
          extension_id: listener.extensionId,
          result: out == null ? "" : String(out),
          notifications: ui.notifications,
        });
      } catch (err) {
        results.push({
          ok: false,
          extension_id: listener.extensionId,
          error: err instanceof Error ? err.message : String(err),
          notifications: ui.notifications,
        });
      }
    }
    return [{ ...base, kind: "hook_done", payload: { event, results } }];
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
