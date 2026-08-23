#!/usr/bin/env node
/**
 * Persistent Jackal plugin host (D11/D13/D21).
 *
 * Speaks one JSON Envelope per line on stdio. Started concurrently with the
 * Jac session when extensions are declared — must not block the first frame
 * on the Jac side.
 *
 * Wire kinds: host_hello, host_goodbye, host_status, ext_load, ext_unload,
 * ext_loaded, tool_invoke, tool_result, tool_cancel, tool_update,
 * ui_request/ui_response (P12 interactive round-trips).
 *
 * Dispatch semantics:
 * - tool_invoke dispatches concurrently (never awaited by the reader).
 * - load/unload/cmd_invoke/hook_fire run on a SERIAL promise chain that is
 *   NOT awaited by the stdin iterator — a handler blocking on ui.select()
 *   can no longer deadlock the reader (P12 finding #1).
 * - ui_response is an immediate fast path that settles pending UI promises.
 */

import readline from "node:readline";
import { createHostState, handleEnvelope, HOST_CAPS, COMPAT_TIER } from "./pi_shim.mjs";

const PROTOCOL = 1;
const state = createHostState();

function writeEnv(partial) {
  const out = {
    version: partial.version ?? 1,
    session_id: partial.session_id ?? "",
    request_id: partial.request_id ?? "",
    turn_id: partial.turn_id ?? "",
    tool_id: partial.tool_id ?? "",
    sequence: partial.sequence ?? 0,
    correlation_id: partial.correlation_id ?? "",
    kind: partial.kind ?? "",
    payload: partial.payload ?? {},
  };
  process.stdout.write(JSON.stringify(out) + "\n");
}

writeEnv({
  kind: "host_hello",
  payload: {
    protocol: PROTOCOL,
    node: process.version,
    caps: HOST_CAPS,
    compat: COMPAT_TIER,
    compat_label: "Pi tool-extension compatibility",
  },
});

const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });

let closed = false;
const inFlight = new Map(); // correlation_id -> AbortController

// ==================== P12: interactive-UI promise broker ====================

const DEFAULT_UI_TIMEOUT_MS = 30000;

const pendingUi = new Map(); // childCorr -> { settle, timer }
const childrenByParent = new Map(); // parentCorr -> Set<childCorr>
let uiCounter = 0;

function trackChild(parentCorr, childCorr) {
  let set = childrenByParent.get(parentCorr);
  if (!set) {
    set = new Set();
    childrenByParent.set(parentCorr, set);
  }
  set.add(childCorr);
}

function untrackChild(parentCorr, childCorr) {
  const set = childrenByParent.get(parentCorr);
  if (set) {
    set.delete(childCorr);
    if (!set.size) {
      childrenByParent.delete(parentCorr);
    }
  }
}

/** Settle one pending request exactly once; first terminal action wins. */
function settleUi(childCorr, outcome) {
  const p = pendingUi.get(childCorr);
  if (!p) {
    return false; // late reply / already settled — ignored
  }
  clearTimeout(p.timer);
  pendingUi.delete(childCorr);
  untrackChild(p.parentCorr ?? "", childCorr);
  p.settle(outcome);
  return true;
}

/** Send a ui_request and return a promise settled by ui_response or local
 * timeout. The child correlation id is minted here — never the parent's. */
function requestUi(parentCorr, extensionId, method, payload, callOpts) {
  return new Promise((resolve) => {
    const childCorr = `ui-${++uiCounter}`;
    const timeoutMs = Math.max(
      1000,
      Number(callOpts?.timeout) > 0 ? Number(callOpts.timeout) : DEFAULT_UI_TIMEOUT_MS,
    );
    const timer = setTimeout(() => {
      settleUi(childCorr, { ok: false, reason: "timeout" });
    }, timeoutMs);

    const p = {
      timer,
      parentCorr,
      settle: resolve,
    };
    pendingUi.set(childCorr, p);
    trackChild(parentCorr, childCorr);

    writeEnv({
      kind: "ui_request",
      correlation_id: childCorr,
      payload: {
        parent_correlation_id: parentCorr || "",
        extension_id: extensionId || "",
        method,
        ...payload,
        timeout_ms: timeoutMs,
      },
    });
  });
}

/** Inbound ui_response from Jac (TUI answer or expiry/cancel). */
function resolveUi(env) {
  const status = env.payload?.status;
  const corr = env.correlation_id || "";
  const p = pendingUi.get(corr);
  const parentCorr = p?.parentCorr ?? "";
  const outcome =
    status === "ok"
      ? { ok: true, value: env.payload?.value }
      : { ok: false, reason: String(env.payload?.reason ?? status ?? "cancelled") };
  settleUi(corr, outcome); // settles + untracks internally
}

/** Parent finished (replied/failed) — cancel its outstanding children so
 * handlers awaiting UI cannot outlive their parent interaction. */
function cancelUiForParent(parentCorr, reason) {
  const set = childrenByParent.get(parentCorr);
  if (!set || !set.size) {
    return 0;
  }
  const children = [...set];
  let n = 0;
  for (const child of children) {
    // Tell Jac to drop the queued modal, then settle locally.
    if (pendingUi.has(child)) {
      writeEnv({
        kind: "ui_cancel",
        correlation_id: child,
        payload: { reason },
      });
      if (settleUi(child, { ok: false, reason })) {
        n += 1;
      }
    }
  }
  return n;
}

function cancelAllUi(reason) {
  let n = 0;
  for (const parent of [...childrenByParent.keys()]) {
    n += cancelUiForParent(parent, reason);
  }
  return n;
}

// ==================== dispatch plumbing ====================

async function runInvoke(env) {
  const corr = env.correlation_id || "";
  const ac = new AbortController();
  if (corr) {
    inFlight.set(corr, ac);
  }
  try {
    const replies = await handleEnvelope(state, env, {
      signal: ac.signal,
      onUpdate: (update) => {
        writeEnv({
          version: env.version,
          session_id: env.session_id,
          correlation_id: corr,
          tool_id: env.tool_id || env.payload?.name || "",
          kind: "tool_update",
          payload: update && typeof update === "object" ? update : { text: String(update ?? "") },
        });
      },
    });
    for (const reply of replies) {
      writeEnv(reply);
    }
  } catch (err) {
    writeEnv({
      version: env.version,
      session_id: env.session_id,
      correlation_id: corr,
      tool_id: env.tool_id || "",
      kind: "tool_result",
      payload: {
        ok: false,
        error: err instanceof Error ? err.message : String(err),
      },
    });
  } finally {
    if (corr) {
      inFlight.delete(corr);
      cancelUiForParent(corr, "parent-finished");
    }
  }
}

/** Serial work chain for load/unload/cmd_invoke/hook_fire. The stdin
 * iterator enqueues and moves on; a blocked handler cannot stall reads. */
let serialChain = Promise.resolve();

function enqueueSerial(env) {
  serialChain = serialChain
    .then(async () => {
      if (closed) {
        return;
      }
      const corr = env.correlation_id || "";
      try {
        const replies = await handleEnvelope(state, env, {
          uiRequest: requestUi,
          signal: undefined,
        });
        for (const reply of replies) {
          writeEnv(reply);
        }
      } catch (err) {
        writeEnv({
          version: env.version,
          session_id: env.session_id,
          correlation_id: corr,
          kind: "host_status",
          payload: {
            phase: "degraded",
            detail: err instanceof Error ? err.message : String(err),
          },
        });
      } finally {
        if (corr) {
          cancelUiForParent(corr, "parent-finished");
        }
      }
    })
    .catch(() => {
      /* chain must never reject */
    });
}

for await (const line of rl) {
  if (closed) {
    break;
  }
  const trimmed = line.trim();
  if (!trimmed) {
    continue;
  }
  let env;
  try {
    env = JSON.parse(trimmed);
  } catch (err) {
    writeEnv({
      kind: "host_status",
      payload: {
        phase: "degraded",
        detail: `bad json: ${err instanceof Error ? err.message : String(err)}`,
      },
    });
    continue;
  }

  if (env.kind === "host_goodbye") {
    closed = true;
    for (const ac of inFlight.values()) {
      try {
        ac.abort();
      } catch {
        /* ignore */
      }
    }
    cancelAllUi("shutdown");
    writeEnv({
      version: env.version,
      session_id: env.session_id,
      correlation_id: env.correlation_id,
      kind: "host_goodbye",
      payload: { reason: env.payload?.reason ?? "dispose" },
    });
    break;
  }

  if (env.kind === "ui_response") {
    // Immediate fast path — never queue behind a blocked handler.
    resolveUi(env);
    continue;
  }

  if (env.kind === "ui_cancel") {
    // Jac-side cancellation of a child we may still hold.
    const corr2 = env.correlation_id || "";
    if (pendingUi.has(corr2)) {
      settleUi(corr2, {
        ok: false,
        reason: String(env.payload?.reason ?? "cancelled"),
      });
    }
    continue;
  }

  if (env.kind === "tool_cancel") {
    const corr = env.correlation_id || "";
    const ac = corr ? inFlight.get(corr) : null;
    if (ac) {
      ac.abort();
    }
    // Also mark cancelled in state for late checks — fire-and-forget to
    // keep the reader non-blocking.
    void handleEnvelope(state, env, {}).catch(() => {});
    continue;
  }

  if (env.kind === "tool_invoke") {
    // Concurrent dispatch — do not await before reading next line.
    void runInvoke(env);
    continue;
  }

  // Serial path for load/unload/cmd_invoke/hook_fire/unknown: enqueue and
  // keep reading. Order is preserved; blocking handlers degrade, not stall.
  enqueueSerial(env);
}

process.exit(0);
