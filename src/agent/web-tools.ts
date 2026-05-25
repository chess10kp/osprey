// Web search (Brave) and URL fetch tools for the agent harness.

import { Type } from "typebox";
import type { AgentTool } from "@earendil-works/pi-agent-core";
import { truncateToolOutput } from "./tool-output-limit.js";

const BRAVE_SEARCH_URL = "https://api.search.brave.com/res/v1/web/search";
const DEFAULT_SEARCH_COUNT = 5;
const MAX_SEARCH_COUNT = 10;
const DEFAULT_FETCH_TIMEOUT_MS = 30_000;
const MAX_FETCH_BODY_BYTES = 512 * 1024;
const USER_AGENT = "Jackal/0.1 (+https://github.com/jaseci/jackal)";

export function braveApiKey(): string | undefined {
  return (
    process.env.BRAVE_API_KEY?.trim() ||
    process.env.BRAVE_SEARCH_API_KEY?.trim() ||
    undefined
  );
}

/** Block SSRF targets (localhost, private IPs, non-http(s)). */
export function assertSafeFetchUrl(raw: string): URL {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new Error(`Invalid URL: ${raw}`);
  }

  if (url.protocol !== "http:" && url.protocol !== "https:") {
    throw new Error("Only http(s) URLs are allowed");
  }

  const host = url.hostname.toLowerCase();
  if (
    host === "localhost" ||
    host.endsWith(".localhost") ||
    host === "127.0.0.1" ||
    host === "0.0.0.0" ||
    host === "::1" ||
    host === "[::1]"
  ) {
    throw new Error("Loopback URLs are not allowed");
  }

  if (host === "metadata.google.internal" || host.endsWith(".internal")) {
    throw new Error("Internal hostnames are not allowed");
  }

  if (isPrivateOrLinkLocalHost(host)) {
    throw new Error("Private network URLs are not allowed");
  }

  return url;
}

function isPrivateOrLinkLocalHost(host: string): boolean {
  const bare = host.startsWith("[") && host.endsWith("]") ? host.slice(1, -1) : host;

  if (bare.includes(":")) {
    const h = bare.toLowerCase();
    if (h === "::1") return true;
    if (h.startsWith("fc") || h.startsWith("fd")) return true;
    if (h.startsWith("fe80:")) return true;
    return false;
  }

  const parts = bare.split(".").map((p) => Number(p));
  if (parts.length !== 4 || parts.some((n) => !Number.isInteger(n) || n < 0 || n > 255)) {
    return false;
  }

  const [a, b] = parts;
  if (a === 10) return true;
  if (a === 127) return true;
  if (a === 169 && b === 254) return true;
  if (a === 172 && b >= 16 && b <= 31) return true;
  if (a === 192 && b === 168) return true;
  return false;
}

export function htmlToReadableText(html: string): string {
  let text = html
    .replace(/<script[\s\S]*?<\/script>/gi, "")
    .replace(/<style[\s\S]*?<\/style>/gi, "")
    .replace(/<noscript[\s\S]*?<\/noscript>/gi, "")
    .replace(/<!--[\s\S]*?-->/g, "");

  text = text
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<\/(p|div|section|article|header|footer|li|tr|h[1-6])>/gi, "\n")
    .replace(/<li[^>]*>/gi, "- ")
    .replace(/<[^>]+>/g, " ");

  text = decodeBasicEntities(text);
  text = text.replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n").replace(/[ \t]{2,}/g, " ");
  return text.trim();
}

function decodeBasicEntities(text: string): string {
  return text
    .replace(/&nbsp;/gi, " ")
    .replace(/&amp;/gi, "&")
    .replace(/&lt;/gi, "<")
    .replace(/&gt;/gi, ">")
    .replace(/&quot;/gi, '"')
    .replace(/&#39;/g, "'")
    .replace(/&#x([0-9a-f]+);/gi, (_, hex) => String.fromCodePoint(parseInt(hex, 16)))
    .replace(/&#(\d+);/g, (_, num) => String.fromCodePoint(Number(num)));
}

export interface WebSearchResult {
  title: string;
  url: string;
  description: string;
}

export function formatWebSearchResults(results: WebSearchResult[]): string {
  if (results.length === 0) return "No results found.";
  return results
    .map((r, i) => {
      const lines = [`${i + 1}. ${r.title}`, `   URL: ${r.url}`];
      if (r.description) lines.push(`   ${r.description}`);
      return lines.join("\n");
    })
    .join("\n\n");
}

export function parseBraveSearchResponse(data: unknown): WebSearchResult[] {
  if (!data || typeof data !== "object") return [];
  const web = (data as { web?: { results?: unknown[] } }).web;
  const rows = web?.results;
  if (!Array.isArray(rows)) return [];

  const out: WebSearchResult[] = [];
  for (const row of rows) {
    if (!row || typeof row !== "object") continue;
    const r = row as Record<string, unknown>;
    const title = String(r.title ?? "").trim();
    const url = String(r.url ?? "").trim();
    const description = String(r.description ?? r.snippet ?? "").trim();
    if (!url) continue;
    out.push({ title: title || url, url, description });
  }
  return out;
}

export async function searchWeb(
  query: string,
  options?: { count?: number },
): Promise<{ results: WebSearchResult[]; raw?: unknown }> {
  const apiKey = braveApiKey();
  if (!apiKey) {
    throw new Error(
      "Web search requires BRAVE_API_KEY (or BRAVE_SEARCH_API_KEY). Get a key at https://api.search.brave.com/",
    );
  }

  const count = Math.min(Math.max(options?.count ?? DEFAULT_SEARCH_COUNT, 1), MAX_SEARCH_COUNT);
  const url = new URL(BRAVE_SEARCH_URL);
  url.searchParams.set("q", query);
  url.searchParams.set("count", String(count));

  const response = await fetch(url, {
    headers: {
      Accept: "application/json",
      "Accept-Encoding": "gzip",
      "X-Subscription-Token": apiKey,
    },
    signal: AbortSignal.timeout(20_000),
  });

  const bodyText = await response.text();
  let data: unknown;
  try {
    data = JSON.parse(bodyText) as unknown;
  } catch {
    throw new Error(`Brave search returned non-JSON (HTTP ${response.status})`);
  }

  if (!response.ok) {
    const msg =
      typeof data === "object" && data !== null && "message" in data
        ? String((data as { message?: unknown }).message)
        : bodyText.slice(0, 200);
    throw new Error(`Brave search failed (HTTP ${response.status}): ${msg}`);
  }

  return { results: parseBraveSearchResponse(data), raw: data };
}

export async function fetchWebPage(
  rawUrl: string,
  options?: { timeoutMs?: number },
): Promise<{ url: string; contentType: string; text: string }> {
  const url = assertSafeFetchUrl(rawUrl);
  const timeoutMs = options?.timeoutMs ?? DEFAULT_FETCH_TIMEOUT_MS;

  const response = await fetch(url, {
    headers: {
      Accept: "text/html,application/xhtml+xml,text/plain,application/json;q=0.9,*/*;q=0.8",
      "User-Agent": USER_AGENT,
    },
    redirect: "follow",
    signal: AbortSignal.timeout(timeoutMs),
  });

  const contentType = response.headers.get("content-type") ?? "application/octet-stream";
  const buffer = Buffer.from(await response.arrayBuffer());
  if (buffer.length > MAX_FETCH_BODY_BYTES) {
    throw new Error(`Response too large (${buffer.length} bytes, max ${MAX_FETCH_BODY_BYTES})`);
  }

  const body = buffer.toString("utf8");
  let text: string;

  if (contentType.includes("application/json")) {
    try {
      text = JSON.stringify(JSON.parse(body), null, 2);
    } catch {
      text = body;
    }
  } else if (contentType.includes("text/html") || contentType.includes("application/xhtml")) {
    const titleMatch = body.match(/<title[^>]*>([\s\S]*?)<\/title>/i);
    const title = titleMatch ? htmlToReadableText(titleMatch[1]!) : "";
    const main = htmlToReadableText(body);
    text = title ? `# ${title}\n\n${main}` : main;
  } else {
    text = body;
  }

  if (!response.ok) {
    throw new Error(`HTTP ${response.status} ${response.statusText}\n\n${truncateToolOutput(text, 4000)}`);
  }

  return { url: response.url || url.href, contentType, text: truncateToolOutput(text) };
}

export function createWebTools(): AgentTool[] {
  const webSearchTool: AgentTool = {
    name: "web_search",
    label: "Web Search",
    description:
      "Search the public web for up-to-date information. Requires BRAVE_API_KEY. Use for docs, releases, and facts not in the repo.",
    parameters: Type.Object({
      search_term: Type.String({ description: "Search query" }),
      explanation: Type.Optional(
        Type.String({ description: "Why this search helps the current task" }),
      ),
      count: Type.Optional(
        Type.Number({ minimum: 1, maximum: MAX_SEARCH_COUNT, description: "Number of results (default 5)" }),
      ),
    }),
    execute: async (_toolCallId, rawParams) => {
      const params = rawParams as { search_term: string; explanation?: string; count?: number };
      const query = params.search_term?.trim();
      if (!query) throw new Error("search_term is required");

      const { results } = await searchWeb(query, { count: params.count });
      const text = formatWebSearchResults(results);

      return {
        content: [{ type: "text", text }],
        details: {
          query,
          count: results.length,
          results,
          explanation: params.explanation,
        },
      };
    },
  };

  const webFetchTool: AgentTool = {
    name: "web_fetch",
    label: "Web Fetch",
    description:
      "Fetch a public URL and return readable text (HTML is stripped to plain text). Use after web_search when you need page content.",
    parameters: Type.Object({
      url: Type.String({ description: "http(s) URL to fetch" }),
    }),
    execute: async (_toolCallId, rawParams) => {
      const params = rawParams as { url: string };
      const target = params.url?.trim();
      if (!target) throw new Error("url is required");

      const result = await fetchWebPage(target);
      const header = `URL: ${result.url}\nContent-Type: ${result.contentType}\n\n`;
      return {
        content: [{ type: "text", text: header + result.text }],
        details: {
          url: result.url,
          contentType: result.contentType,
          bytes: result.text.length,
        },
      };
    },
  };

  return [webSearchTool, webFetchTool];
}
