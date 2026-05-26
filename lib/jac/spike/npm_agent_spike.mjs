#!/usr/bin/env node
/**
 * Phase 0 npm interop spike — pi-agent-core via Node bridge.
 * Invoked by lib/jac/spike/agent_spike.jac (Jac cannot import ESM npm directly).
 *
 * Validates: import, instantiate, one headless turn (prompt → agent_end).
 */
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(__dirname, "..", "..", "..");

const SPIKE_RESPONSE = "headless-ok";
const TURN_TIMEOUT_MS = 10_000;

async function main() {
  const results = { phase: 0, checks: [] };

  function ok(name, detail = "") {
    results.checks.push({ name, ok: true, detail });
  }
  function fail(name, detail) {
    results.checks.push({ name, ok: false, detail });
  }

  let core;
  let ai;
  try {
    const corePath = join(
      repoRoot,
      "node_modules",
      "@earendil-works",
      "pi-agent-core",
      "dist",
      "index.js",
    );
    core = await import(corePath);
    if (!core?.Agent) {
      fail("import pi-agent-core", "Agent export missing");
    } else {
      ok("import pi-agent-core", `Agent=${typeof core.Agent}`);
    }

    const aiPath = join(
      repoRoot,
      "node_modules",
      "@earendil-works",
      "pi-ai",
      "dist",
      "index.js",
    );
    ai = await import(aiPath);
    if (!ai) {
      fail("import pi-ai", "module empty");
    } else {
      ok("import pi-ai", "loaded");
    }
  } catch (err) {
    fail("npm interop", err instanceof Error ? err.message : String(err));
    finish(results);
    return;
  }

  const { Agent } = core;
  const agent = new Agent({
    initialState: {
      systemPrompt: "You are a Phase 0 spike test.",
      model: null,
      tools: [],
    },
    convertToLlm: (messages) => messages,
    transformContext: async (messages) => messages,
  });
  if (agent && typeof agent.prompt === "function") {
    ok("instantiate Agent", "prompt() available");
  } else {
    fail("instantiate Agent", "unexpected Agent shape");
    finish(results);
    return;
  }

  const turn = await runHeadlessTurn(core, ai);
  results.turn = turn;
  if (turn.ok) {
    ok(
      "headless turn",
      `agent_end; events=${turn.eventTypes.length}; text=${turn.responseText}`,
    );
  } else {
    fail("headless turn", turn.error || "turn failed");
  }

  finish(results);
}

/**
 * One automated turn: prompt → stream → agent_end (faux provider, no API keys).
 */
async function runHeadlessTurn(core, ai) {
  const eventTypes = [];
  let responseText = "";
  let faux;

  try {
    const { registerFauxProvider, fauxAssistantMessage } = ai;
    faux = registerFauxProvider({ tokensPerSecond: 0 });
    faux.setResponses([fauxAssistantMessage(SPIKE_RESPONSE)]);

    const { Agent } = core;
    const model = faux.getModel();

    const agent = new Agent({
      initialState: {
        systemPrompt: "Phase 0 spike — respond with the canned line.",
        model,
        tools: [],
      },
    });

    const unsub = agent.subscribe((event) => {
      if (event?.type) eventTypes.push(String(event.type));
      if (event?.type === "message_end" && event.message?.role === "assistant") {
        const textBlock = event.message.content?.find((c) => c.type === "text");
        if (textBlock?.type === "text") responseText = textBlock.text;
      }
    });

    const turnPromise = new Promise((resolve, reject) => {
      let done = false;
      const timeout = setTimeout(() => {
        if (done) return;
        done = true;
        reject(new Error(`timeout after ${TURN_TIMEOUT_MS}ms waiting for agent_end`));
      }, TURN_TIMEOUT_MS);

      const unsubEnd = agent.subscribe((event) => {
        if (event?.type !== "agent_end" || done) return;
        done = true;
        clearTimeout(timeout);
        unsubEnd();
        resolve();
      });

      void agent
        .prompt(`Respond with exactly: ${SPIKE_RESPONSE}`)
        .catch((err) => {
          if (done) return;
          done = true;
          clearTimeout(timeout);
          unsubEnd();
          reject(err);
        });
    });

    await turnPromise;
    await agent.waitForIdle();
    unsub();
    faux.unregister();

    const sawEnd = eventTypes.includes("agent_end");
    const sawStart = eventTypes.includes("agent_start");
    if (!sawEnd || !sawStart) {
      return {
        ok: false,
        error: `missing lifecycle events (start=${sawStart}, end=${sawEnd})`,
        eventTypes,
        responseText,
      };
    }
    if (!responseText.includes(SPIKE_RESPONSE)) {
      return {
        ok: false,
        error: `expected response containing "${SPIKE_RESPONSE}", got "${responseText}"`,
        eventTypes,
        responseText,
      };
    }

    return { ok: true, eventTypes, responseText };
  } catch (err) {
    faux?.unregister?.();
    return {
      ok: false,
      error: err instanceof Error ? err.message : String(err),
      eventTypes,
      responseText,
    };
  }
}

function finish(results) {
  const allOk = results.checks.every((c) => c.ok);
  results.ok = allOk;
  console.log(JSON.stringify(results, null, 2));
  process.exit(allOk ? 0 : 1);
}

main();
