// LLM-based context summarization for /compact and auto-compact.

import { generateSummary, type AgentMessage } from "@earendil-works/pi-agent-core";
import type { Model, Api } from "@earendil-works/pi-ai";

const SUMMARY_RESERVE_TOKENS = 8192;

export function wrapCompactionSummary(text: string): string {
  const trimmed = text.trim();
  if (!trimmed) return "";
  return [
    "<conversation-summary>",
    trimmed,
    "</conversation-summary>",
    "",
    "(The above is an automated summary of earlier conversation. Continue from the most recent message.)",
  ].join("\n");
}

/**
 * Summarize dropped messages with the active model.
 * Returns null when auth is missing or the provider call fails.
 */
export async function summarizeForCompaction(
  messages: AgentMessage[],
  model: Model<Api>,
  getApiKey: (provider: string) => Promise<string | undefined>,
  signal?: AbortSignal,
): Promise<string | null> {
  if (messages.length === 0) return null;

  const apiKey = await getApiKey(model.provider);
  if (!apiKey) return null;

  try {
    const result = await generateSummary(
      messages,
      model,
      SUMMARY_RESERVE_TOKENS,
      apiKey,
      undefined,
      signal,
    );
    if (!result.ok) return null;
    const wrapped = wrapCompactionSummary(result.value);
    return wrapped || null;
  } catch {
    return null;
  }
}
