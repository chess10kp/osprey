// Expand @file mentions and !command prefixes into prompt context blocks.
// Delegated to lib/jac/workflow/_context_input_toolchain.py via bridge.

import { bridgeExpandContextInput } from "../jac/jac-bridge.js";

/** Expand `!cmd` prefix and `@path` mentions in user text before sending to the agent. */
export async function expandContextInput(cwd: string, text: string): Promise<string> {
  // Bridge handles sync expansion; wrap in Promise for API compatibility
  return bridgeExpandContextInput(cwd, text);
}
