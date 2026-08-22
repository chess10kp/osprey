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
import { EventEmitter } from "node:events";
import { exec as cpExec } from "node:child_process";

/** Advertised capabilities — grow this list when real support lands. */
export const HOST_CAPS = [
  "tools",
  "cancel",
  "updates",
  "commands",
  "session_hooks",
  "transformers",
  "providers",
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
    /** Extension traffic drains, attached to the next outgoing reply. */
    pendingMessages: [],
    pendingEntries: [],
    sessionName: "",
    /** null = all tools active; array = exactly those. */
    activeTools: null,
    /** Stored registrations (honored surfaces report counts; caps stay honest). */
    shortcuts: [],
    flags: new Map(),
    /** Provider configs by name; each carries ownerExtensionId. */
    providers: new Map(),
    messageRenderers: new Map(),
    entryRenderers: new Map(),
    labels: new Map(),
    modelName: "",
    thinkingLevel: "off",
    /** Inter-extension event bus — local only, never crosses the wire. */
    eventBus: new EventEmitter(),
  };
}

/** UI context handed to command/hook handlers.
 * - notify(message, level) collects into `notifications`.
 * - Display methods collect into `uiEvents` — shipped to the Jac side over
 *   the wire, not rendered here.
 * - Interactive methods CANNOT block over the wire — they resolve
 *   immediately: select->undefined, confirm->false, input/editor->"".
 */
function makeUi(state, extensionId) {
  const bucket = [];
  const uiEvents = [];
  const record = (method, args) => {
    uiEvents.push({ method, args });
  };
  return {
    notifications: bucket,
    uiEvents,
    notify(message, _level) {
      bucket.push(String(message ?? ""));
    },
    setStatus(_owner, text) {
      record("setStatus", [text]);
    },
    setWidget(id, text) {
      record("setWidget", [id, text]);
    },
    setFooter(text) {
      record("setFooter", [text]);
    },
    setTitle(text) {
      record("setTitle", [text]);
    },
    setWorkingMessage(text) {
      record("setWorkingMessage", [text]);
    },
    setHeader(text) {
      record("setHeader", [text]);
    },
    select(_title, _options) {
      return Promise.resolve(undefined);
    },
    confirm(_message) {
      return Promise.resolve(false);
    },
    input(_message, _default) {
      return Promise.resolve("");
    },
    editor(_opts) {
      return Promise.resolve("");
    },
    custom(_component) {
      return Promise.resolve(undefined);
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
  for (const [name, p] of state.providers) {
    if (p.ownerExtensionId === extensionId) {
      state.providers.delete(name);
    }
  }
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

    // ---- message push: real — drained onto the next outgoing reply ----
    sendMessage(msg) {
      if (msg == null) {
        return;
      }
      if (typeof msg === "string") {
        state.pendingMessages.push({ role: "user", content: msg });
      } else {
        state.pendingMessages.push({
          role: String(msg.role ?? "user"),
          content:
            typeof msg.content === "string"
              ? msg.content
              : JSON.stringify(msg.content ?? ""),
        });
      }
    },
    sendUserMessage(text, _opts) {
      api.sendMessage(text == null ? "" : String(text));
    },
    appendEntry(type, data) {
      state.pendingEntries.push({ type: String(type ?? ""), data });
    },

    // ---- tool activity control: enforced at tool_invoke ----
    setActiveTools(names) {
      const list = Array.isArray(names) ? names.map(String) : [];
      state.activeTools = list.length ? list : null;
    },

    getCommands() {
      return [...state.commands.keys()];
    },

    exec(cmd, argsOrOpts, maybeOpts) {
      let command = String(cmd ?? "");
      let opts = {};
      if (Array.isArray(argsOrOpts)) {
        if (argsOrOpts.length) {
          command += " " + argsOrOpts.map(String).join(" ");
        }
        opts = maybeOpts ?? {};
      } else if (argsOrOpts && typeof argsOrOpts === "object") {
        opts = argsOrOpts;
      }
      return new Promise((resolve) => {
        cpExec(
          command,
          { cwd: process.cwd(), ...opts },
          (err, stdout, stderr) => {
            resolve({
              stdout: String(stdout ?? ""),
              stderr: String(stderr ?? ""),
              code: err && typeof err.code === "number" ? err.code : 0,
            });
          },
        );
      });
    },

    setSessionName(name) {
      state.sessionName = String(name ?? "");
    },
    getSessionName() {
      return state.sessionName;
    },

    // ---- stored registrations / typed getters: degrade, never crash ----
    registerShortcut(key, opts) {
      state.shortcuts.push({ key: String(key ?? ""), opts });
    },
    registerFlag(name, opts) {
      state.flags.set(String(name ?? ""), opts ?? {});
    },
    getFlag(name) {
      const f = state.flags.get(String(name ?? ""));
      return f ? f.default : undefined;
    },
    setLabel(id, label) {
      state.labels.set(String(id ?? ""), String(label ?? ""));
    },
    setModel(m) {
      state.modelName = String(m ?? "");
    },
    setThinkingLevel(level) {
      state.thinkingLevel = String(level ?? "off");
    },
    getThinkingLevel() {
      return state.thinkingLevel;
    },
    /** P10: real storage. Models declared here ride the ext_loaded payload
     * so the Jac side can route ext/<extension>/<model> ids. Request
     * mutation happens via the before_provider_request hook. */
    registerProvider(cfg) {
      if (!cfg || typeof cfg !== "object" || typeof cfg.name !== "string" || !cfg.name) {
        throw new Error("registerProvider requires a config object with a name");
      }
      const models = Array.isArray(cfg.models)
        ? cfg.models.map((m) => (typeof m === "string" ? { id: m } : m))
        : [];
      state.providers.set(cfg.name, {
        name: cfg.name,
        models,
        baseUrl: cfg.baseUrl ?? "",
        streaming: cfg.streaming !== false,
        ownerExtensionId: extensionId,
      });
    },
    unregisterProvider(name) {
      const p = state.providers.get(String(name ?? ""));
      if (p && p.ownerExtensionId === extensionId) {
        state.providers.delete(String(name ?? ""));
      }
    },
    /** Inter-extension event bus (real, local-only). */
    events: {
      on: (...a) => state.eventBus.on(...a),
      off: (...a) => state.eventBus.off(...a),
      emit: (...a) => state.eventBus.emit(...a),
    },

    // ---- renderers: stored so activate never crashes; rendering is T2c ----
    registerMessageRenderer(type, _renderer) {
      state.messageRenderers.set(String(type ?? ""), extensionId);
    },
    registerEntryRenderer(type, _renderer) {
      state.entryRenderers.set(String(type ?? ""), extensionId);
    },
    getActiveTools() {
      if (state.activeTools) {
        return state.activeTools.filter((n) => state.tools.has(n));
      }
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

function providersFor(state, extensionId) {
  const out = [];
  for (const p of state.providers.values()) {
    if (p.ownerExtensionId === extensionId) {
      out.push({
        name: p.name,
        models: p.models.map((m) => ({ id: String(m.id ?? ""), name: String(m.name ?? m.id ?? "") })),
        base_url: p.baseUrl,
        streaming: p.streaming,
      });
    }
  }
  return out;
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
/** Drain extension traffic for attachment to the next outgoing reply. */
function takeTraffic(state) {
  const out = {};
  if (state.pendingMessages.length) {
    out.messages = state.pendingMessages.splice(0);
  }
  if (state.pendingEntries.length) {
    out.entries = state.pendingEntries.splice(0);
  }
  return out;
}

/**
 * Public envelope entry: applies inbound session_name, then decorates every
 * reply with drained extension traffic so spontaneous pushes are never lost.
 */
export async function handleEnvelope(state, env, ctx = {}) {
  const p0 = env?.payload;
  if (p0 && typeof p0 === "object" && "session_name" in p0) {
    state.sessionName = String(p0.session_name ?? "");
  }
  const replies = await handleEnvelopeInner(state, env, ctx);
  const extra = takeTraffic(state);
  for (const r of replies) {
    if (!r || typeof r !== "object" || !r.payload || typeof r.payload !== "object") {
      continue;
    }
    if (extra.messages && !r.payload.messages) {
      r.payload.messages = extra.messages;
    }
    if (extra.entries && !r.payload.entries) {
      r.payload.entries = extra.entries;
    }
    if (state.sessionName && r.payload.session_name === undefined) {
      r.payload.session_name = state.sessionName;
    }
  }
  return replies;
}

async function handleEnvelopeInner(state, env, ctx = {}) {
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
            providers: providersFor(state, id),
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
      const payload = {
        ok: true,
        result: result == null ? "" : String(result),
        notifications: ui.notifications,
      };
      if (ui.uiEvents.length) {
        payload.ui_events = ui.uiEvents;
      }
      return [{ ...base, kind: "cmd_result", payload }];
    } catch (err) {
      const payload = {
        ok: false,
        error: err instanceof Error ? err.message : String(err),
        notifications: ui.notifications,
      };
      if (ui.uiEvents.length) {
        payload.ui_events = ui.uiEvents;
      }
      return [{ ...base, kind: "cmd_result", payload }];
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
    // Structured-verdict events (tool_call input chaining, context message
    // edits) get a deep working copy handlers mutate IN PLACE; later handlers
    // see earlier mutations — Pi semantics. The final copy echoes back so the
    // Jac side observes chained mutations without per-handler round trips.
    const MUTABLE_EVENTS = new Set(["tool_call", "context", "input"]);
    const working = MUTABLE_EVENTS.has(event)
      ? JSON.parse(JSON.stringify(data ?? {}))
      : data;
    const listeners = state.listeners.get(event) ?? [];
    const results = [];
    for (const listener of listeners) {
      const ui = makeUi(state, listener.extensionId);
      let entry = {};
      try {
        const out = await listener.handler(working, { ui });
        // Transform verdicts rewrite the working text so later handlers see
        // the composed input (Pi input-transform chaining).
        if (
          out &&
          typeof out === "object" &&
          out.action === "transform" &&
          out.text != null
        ) {
          working.text = String(out.text);
        }
        entry = {
          ok: true,
          extension_id: listener.extensionId,
          result: out == null ? "" : String(out),
          // Structured verdict ({block}, {action}, {messages}, {systemPrompt})
          // kept as a raw object; null when the handler returned a scalar.
          verdict:
            out && typeof out === "object" && !Array.isArray(out) ? out : null,
          notifications: ui.notifications,
        };
      } catch (err) {
        entry = {
          ok: false,
          extension_id: listener.extensionId,
          error: err instanceof Error ? err.message : String(err),
          verdict: null,
          notifications: ui.notifications,
        };
      }
      if (ui.uiEvents.length) {
        entry.ui_events = ui.uiEvents;
      }
      results.push(entry);
    }
    const payload = { event, results };
    if (working !== data) {
      payload.data = working;
    }
    return [{ ...base, kind: "hook_done", payload }];
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
    if (state.activeTools && !state.activeTools.includes(name)) {
      return [
        {
          ...base,
          kind: "tool_result",
          tool_id: name,
          payload: { ok: false, error: `tool ${name} is not active` },
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
