// Tool output limits — cap payloads before they enter agent context, UI, or persistence.
//
// Nanocoder truncates per-tool at the formatter (e.g. bash → 2k chars via
// TRUNCATION_OUTPUT_LIMIT) and uses retry caps to avoid heap exhaustion loops.
// Jackal applies one byte budget at the tool boundary so every tool path is covered.

import type { AgentTool } from "@earendil-works/pi-agent-core";

/** Maximum tool output size returned to the model and stored in the TUI (50 KiB). */
export const MAX_TOOL_OUTPUT_BYTES = 50 * 1024;

const TRUNCATION_SUFFIX = "\n...[truncated at 50 KB]";

type ToolExecuteResult = Awaited<ReturnType<AgentTool["execute"]>>;

/** Truncate UTF-8 text to at most `maxBytes` without splitting a code point. */
export function truncateToolOutput(
  text: string,
  maxBytes: number = MAX_TOOL_OUTPUT_BYTES,
): string {
  if (!text) return text;
  const encoded = Buffer.from(text, "utf8");
  if (encoded.length <= maxBytes) return text;

  const suffixBytes = Buffer.byteLength(TRUNCATION_SUFFIX, "utf8");
  const budget = Math.max(0, maxBytes - suffixBytes);
  let end = budget;
  while (end > 0 && (encoded[end]! & 0xc0) === 0x80) {
    end--;
  }
  return encoded.subarray(0, end).toString("utf8") + TRUNCATION_SUFFIX;
}

/** Truncate arbitrary tool result payloads for bridge / UI display. */
export function truncateToolPayload(value: unknown): string | undefined {
  if (value === undefined || value === null) return undefined;
  if (typeof value === "string") return truncateToolOutput(value);
  if (typeof value === "object" && value !== null && "error" in value) {
    return truncateToolOutput(String((value as { error?: unknown }).error ?? "Tool failed"));
  }
  try {
    return truncateToolOutput(JSON.stringify(value));
  } catch {
    return truncateToolOutput(String(value));
  }
}

function limitToolDetails(details: unknown): unknown {
  if (details === undefined || details === null) return details;
  if (typeof details === "string") return truncateToolOutput(details);
  try {
    const serialized = JSON.stringify(details);
    if (Buffer.byteLength(serialized, "utf8") <= MAX_TOOL_OUTPUT_BYTES) {
      return details;
    }
    return {
      truncated: true,
      preview: truncateToolOutput(serialized),
    };
  } catch {
    return details;
  }
}

/** Apply the output cap to a single tool execute result. */
export function limitToolResultContent(result: ToolExecuteResult): ToolExecuteResult {
  const content = result.content?.map((part) => {
    if (part.type === "text" && typeof part.text === "string") {
      return { ...part, text: truncateToolOutput(part.text) };
    }
    return part;
  });

  return {
    ...result,
    ...(content ? { content } : {}),
    ...(result.details !== undefined ? { details: limitToolDetails(result.details) } : {}),
  };
}

/** Wrap a tool so every execute path is capped (core, MCP, subagent, etc.). */
export function wrapToolOutputLimit(tool: AgentTool): AgentTool {
  const execute = tool.execute.bind(tool);
  return {
    ...tool,
    execute: async (toolCallId, params, signal, onUpdate) => {
      const result = await execute(toolCallId, params, signal, onUpdate);
      return limitToolResultContent(result);
    },
  };
}

export function wrapToolsOutputLimit(tools: AgentTool[]): AgentTool[] {
  return tools.map(wrapToolOutputLimit);
}
