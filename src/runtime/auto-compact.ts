// Auto-compact — automatic context compaction triggered at context % threshold.

import type { AgentMessage } from "@earendil-works/pi-agent-core";
import type { ContextUsage } from "./context-usage.js";

export interface AutoCompactConfig {
  enabled: boolean;
  /** Trigger compaction when context usage exceeds this percent (default 80). */
  thresholdPercent: number;
  /** Number of recent messages to keep (default 12). */
  keepTail: number;
  /** Notify the user when auto-compact runs. */
  notify: boolean;
}

export const DEFAULT_AUTO_COMPACT: AutoCompactConfig = {
  enabled: true,
  thresholdPercent: 80,
  keepTail: 12,
  notify: true,
};

export function resolveAutoCompactConfig(raw: {
  autoCompact?: boolean | Partial<AutoCompactConfig>;
}): AutoCompactConfig {
  if (raw.autoCompact === false) {
    return { ...DEFAULT_AUTO_COMPACT, enabled: false };
  }
  if (raw.autoCompact === true) {
    return { ...DEFAULT_AUTO_COMPACT, enabled: true };
  }
  if (raw.autoCompact && typeof raw.autoCompact === "object") {
    return {
      ...DEFAULT_AUTO_COMPACT,
      ...raw.autoCompact,
    };
  }
  return { ...DEFAULT_AUTO_COMPACT };
}

export interface AutoCompactResult {
  triggered: boolean;
  reason?: string;
  dropped?: number;
  messageCountBefore?: number;
  messageCountAfter?: number;
}

/**
 * Build a mechanical summary of dropped messages.
 * This is used when no LLM summary is available (headless / no model).
 */
export function buildMechanicalSummary(messages: AgentMessage[]): string {
  const lines: string[] = [
    "<context-summary>",
    "Earlier conversation context (auto-compacted for space):",
    "",
  ];

  for (const msg of messages) {
    const role = (msg as { role?: string }).role ?? "unknown";
    const content = (msg as { content?: unknown }).content;
    let text = "";
    if (typeof content === "string") {
      text = content;
    } else if (Array.isArray(content)) {
      text = content
        .map((part) => {
          if (typeof part === "string") return part;
          if (part && typeof part === "object" && "text" in part) {
            return String((part as { text?: string }).text ?? "");
          }
          if (part && typeof part === "object" && "type" in part && (part as { type?: string }).type === "toolCall") {
            return `[tool call: ${(part as { name?: string }).name ?? "unknown"}]`;
          }
          return "";
        })
        .filter(Boolean)
        .join(" | ");
    }

    const truncated = text.length > 300 ? `${text.slice(0, 297)}...` : text;
    lines.push(`[${role}] ${truncated}`);
  }

  lines.push("</context-summary>");
  return lines.join("\n");
}

/**
 * Check if auto-compact should trigger based on context usage.
 */
export function shouldAutoCompact(
  usage: ContextUsage,
  config: AutoCompactConfig,
): boolean {
  if (!config.enabled) return false;
  return usage.percent >= config.thresholdPercent;
}

/**
 * Build the compaction prompt for LLM-based summarization.
 * The agent can use this to ask the model to summarize older context.
 */
export function buildLlmSummaryPrompt(messages: AgentMessage[]): string {
  const previews: string[] = [];
  for (const msg of messages) {
    const role = (msg as { role?: string }).role ?? "unknown";
    const content = (msg as { content?: unknown }).content;
    let text = "";
    if (typeof content === "string") {
      text = content;
    } else if (Array.isArray(content)) {
      text = content
        .map((part) => {
          if (typeof part === "string") return part;
          if (part && typeof part === "object" && "text" in part) {
            return String((part as { text?: string }).text ?? "");
          }
          return "";
        })
        .filter(Boolean)
        .join(" | ");
    }
    const truncated = text.length > 200 ? `${text.slice(0, 197)}...` : text;
    previews.push(`[${role}] ${truncated}`);
  }

  return [
    "Summarize the following conversation context in 200 words or less.",
    "Preserve key facts: file paths, function/class names, error messages, decisions made, and any code patterns discussed.",
    "Do NOT include pleasantries or filler — only technical substance.",
    "",
    ...previews,
  ].join("\n");
}
