#!/usr/bin/env node
/**
 * Persistent Jackal plugin host (D11/D13).
 *
 * Speaks one JSON Envelope per line on stdio. Not on Jackal's default startup
 * path — Jac spawns this lazily via agent.plugin_bridge.
 *
 * Wire kinds (brain <-> host): host_hello, host_goodbye, host_status,
 * ext_load, ext_unload, ext_loaded, tool_invoke, tool_result, tool_cancel.
 */

import readline from "node:readline";
import { createHostState, handleEnvelope } from "./pi_shim.mjs";

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
    caps: ["tools"],
  },
});

const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });

// Serial line processing — async handlers must not race (goodbye vs load).
for await (const line of rl) {
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
    writeEnv({
      version: env.version,
      session_id: env.session_id,
      correlation_id: env.correlation_id,
      kind: "host_goodbye",
      payload: { reason: env.payload?.reason ?? "dispose" },
    });
    break;
  }

  try {
    const replies = await handleEnvelope(state, env);
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
