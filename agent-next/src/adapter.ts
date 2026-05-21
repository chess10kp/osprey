import { createAgentSession, SessionManager } from "@earendil-works/pi-coding-agent";

export interface NextAgentSmokeResult {
  ok: boolean;
  eventTypes: string[];
  error?: string;
}

/**
 * Phase-0 smoke: prove Jackal can boot a headless Pi session in-process
 * and execute one prompt loop without the standalone pi CLI.
 */
export async function runNextAgentSmoke(cwd: string): Promise<NextAgentSmokeResult> {
  const eventTypes = new Set<string>();

  try {
    const { session } = await createAgentSession({
      cwd,
      sessionManager: SessionManager.inMemory(cwd),
      noTools: "all",
    });

    const unsubscribe = session.subscribe((event: any) => {
      if (event?.type) eventTypes.add(String(event.type));
    });

    try {
      await session.sendUserMessage("Respond with exactly: headless-ok");
    } finally {
      unsubscribe();
      session.dispose();
    }

    return { ok: true, eventTypes: [...eventTypes] };
  } catch (err: any) {
    return {
      ok: false,
      eventTypes: [...eventTypes],
      error: err?.message || String(err),
    };
  }
}
