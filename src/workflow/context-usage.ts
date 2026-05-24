// Context window usage estimation for Jackal sessions.

import type { AgentMessage } from "@earendil-works/pi-agent-core";
import type { Model, Api } from "@earendil-works/pi-ai";

/** Rough token estimate: characters / 4. */
export const CHARS_PER_TOKEN = 4;

const DEFAULT_CONTEXT_MAX = 128_000;

export interface ContextUsage {
  used: number;
  max: number;
  percent: number;
  systemPromptTokens: number;
  messageTokens: number;
}

function messageToText(message: AgentMessage): string {
  const content = (message as { content?: unknown }).content;
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .map((part) => {
        if (typeof part === "string") return part;
        if (part && typeof part === "object") {
          const p = part as { type?: string; text?: string };
          if (p.type === "text" && p.text) return p.text;
          return JSON.stringify(part);
        }
        return String(part);
      })
      .join("\n");
  }
  if (content != null) return JSON.stringify(content);
  return "";
}

export function estimateTokens(text: string): number {
  if (!text) return 0;
  return Math.ceil(text.length / CHARS_PER_TOKEN);
}

export function estimateMessagesTokens(messages: AgentMessage[]): number {
  let total = 0;
  for (const msg of messages) {
    total += estimateTokens(messageToText(msg));
    total += 4; // role/overhead fudge
  }
  return total;
}

export function getContextMax(
  model?: Model<Api>,
  override?: number | null,
): number {
  if (typeof override === "number" && override > 0) return override;
  const window = model?.contextWindow;
  if (typeof window === "number" && window > 0) return window;
  return DEFAULT_CONTEXT_MAX;
}

export function computeContextUsage(options: {
  messages: AgentMessage[];
  systemPrompt?: string;
  model?: Model<Api>;
  contextMaxOverride?: number | null;
}): ContextUsage {
  const systemPromptTokens = estimateTokens(options.systemPrompt ?? "");
  const messageTokens = estimateMessagesTokens(options.messages);
  const used = systemPromptTokens + messageTokens;
  const max = getContextMax(options.model, options.contextMaxOverride);
  const percent = max > 0 ? Math.min(100, Math.round((used / max) * 100)) : 0;
  return { used, max, percent, systemPromptTokens, messageTokens };
}

export function formatUsageLine(usage: ContextUsage): string {
  return `Context: ${usage.used.toLocaleString()} / ${usage.max.toLocaleString()} tokens (${usage.percent}%)`;
}
