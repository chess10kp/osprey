#!/usr/bin/env node
/**
 * Persistent Jackal plugin host (D11/D13/D21).
 *
 * Speaks one JSON Envelope per line on stdio. Started concurrently with the
 * Jac session when extensions are declared — must not block the first frame
 * on the Jac side.
 *
 * Wire kinds: host_hello, host_goodbye, host_status, ext_load, ext_unload,
 * ext_loaded, tool_invoke, tool_result, tool_cancel, tool_update.
 *
 * Tool invokes dispatch concurrently; load/unload/goodbye stay serial.
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
    }
  }
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
    writeEnv({
      version: env.version,
      session_id: env.session_id,
      correlation_id: env.correlation_id,
      kind: "host_goodbye",
      payload: { reason: env.payload?.reason ?? "dispose" },
    });
    break;
  }

  if (env.kind === "tool_cancel") {
    const corr = env.correlation_id || "";
    const ac = corr ? inFlight.get(corr) : null;
    if (ac) {
      ac.abort();
    }
    // Also mark cancelled in state for late checks.
    try {
      await handleEnvelope(state, env, {});
    } catch {
      /* ignore */
    }
    continue;
  }

  if (env.kind === "tool_invoke") {
    // Concurrent dispatch — do not await before reading next line.
    void runInvoke(env);
    continue;
  }

  // Serial path for load / unload / unknown.
  try {
    const replies = await handleEnvelope(state, env, {});
    for (const reply of replies) {
      writeEnv(reply);
    }
  } catch (err) {
    writeEnv({
      version: env.version,
      session_id: env.session_id,
      correlation_id: env.correlation_id,
      kind: "host_status",
      payload: {
        phase: "degraded",
        detail: err instanceof Error ? err.message : String(err),
      },
    });
  }
}

process.exit(0);
