// Web search and fetch tools backed by pi-web-access (https://github.com/nicobailon/pi-web-access).
// The library surface is bundled to dist/web-access.mjs by scripts/build-web-access.mjs
// (the npm package ships raw TypeScript, which Node refuses to load from node_modules).

import { Type } from "typebox";
import type { AgentTool } from "@earendil-works/pi-agent-core";
import { truncateToolOutput } from "./tool-output-limit.js";

const MAX_SEARCH_RESULTS = 20;
const DEFAULT_SEARCH_RESULTS = 5;

/** Structural types for the bundled pi-web-access modules. */
export interface WebSearchResult {
  title: string;
  url: string;
  snippet?: string;
}

interface WebAccessSearchOptions {
  numResults?: number;
  recencyFilter?: "day" | "week" | "month" | "year";
  domainFilter?: string[];
  provider?: string;
  signal?: AbortSignal;
}

interface WebAccessSearchResponse {
  answer: string;
  results: WebSearchResult[];
  provider?: string;
}

interface WebAccessExtractedContent {
  url: string;
  title: string;
  content: string;
  error: string | null;
  mimeType?: string;
  status?: number;
}

interface WebAccessModule {
  search(query: string, options?: WebAccessSearchOptions): Promise<WebAccessSearchResponse>;
  extractContent(
    url: string,
    signal?: AbortSignal,
    options?: Record<string, unknown>,
  ): Promise<WebAccessExtractedContent>;
}

let webAccessModule: Promise<WebAccessModule> | undefined;

/**
 * Import the bundled pi-web-access surface. The specifier is assembled at
 * runtime so tsc does not try to resolve dist/web-access.mjs during build.
 */
export function loadWebAccess(): Promise<WebAccessModule> {
  webAccessModule ??= import(/* @vite-ignore */ "../" + "web-access.mjs") as Promise<WebAccessModule>;
  return webAccessModule;
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

export function formatWebSearchResults(results: WebSearchResult[]): string {
  if (!Array.isArray(results) || results.length === 0) return "No results found.";
  return results
    .map((r, i) => {
      const lines = [`${i + 1}. ${r.title}`, `   URL: ${r.url}`];
      const description = r.snippet ?? (r as { description?: string }).description;
      if (description) lines.push(`   ${description}`);
      return lines.join("\n");
    })
    .join("\n\n");
}

/** Render a pi-web-access search response: synthesized answer plus source list. */
export function formatWebSearchResponse(response: WebAccessSearchResponse): string {
  const sections: string[] = [];
  const answer = typeof response.answer === "string" ? response.answer.trim() : "";
  if (answer) sections.push(answer);
  const sources = formatWebSearchResults(response.results ?? []);
  if (response.results?.length) {
    sections.push(sources);
  } else if (!answer) {
    return "No results found.";
  }
  return sections.join("\n\n");
}

export async function searchWeb(
  query: string,
  options?: {
    numResults?: number;
    recencyFilter?: "day" | "week" | "month" | "year";
    domainFilter?: string[];
    provider?: string;
  },
): Promise<WebAccessSearchResponse> {
  const numResults =
    options?.numResults === undefined
      ? undefined
      : Math.min(Math.max(Math.floor(options.numResults), 1), MAX_SEARCH_RESULTS);
  return loadWebAccess().then((m) =>
    m.search(query, {
      numResults: numResults ?? DEFAULT_SEARCH_RESULTS,
      recencyFilter: options?.recencyFilter,
      domainFilter: options?.domainFilter,
      provider: options?.provider,
    }),
  );
}

export async function fetchWebPage(rawUrl: string): Promise<WebAccessExtractedContent> {
  assertSafeFetchUrl(rawUrl);
  const result = await loadWebAccess().then((m) => m.extractContent(rawUrl));
  if ((!result.content || result.content.trim() === "") && result.error) {
    throw new Error(`Fetch failed for ${rawUrl}: ${result.error}`);
  }
  return result;
}

export function createWebTools(): AgentTool[] {
  const webSearchTool: AgentTool = {
    name: "web_search",
    label: "Web Search",
    description:
      'Search the web for up-to-date information via a provider fallback chain ' +
      "(SearXNG, OpenAI/Codex, Exa, Brave, Tavily, Kagi, Perplexity, Gemini, and more). " +
      "Returns a synthesized answer with sources. Providers are configured in " +
      "~/.pi/web-search.json or env keys (BRAVE_API_KEY, EXA_API_KEY, ...); " +
      "Exa needs no key. Use for docs, releases, and facts not in the repo.",
    parameters: Type.Object({
      query: Type.String({ description: "Search query" }),
      numResults: Type.Optional(
        Type.Number({
          minimum: 1,
          maximum: MAX_SEARCH_RESULTS,
          description: `Results per provider (default ${DEFAULT_SEARCH_RESULTS})`,
        }),
      ),
      recencyFilter: Type.Optional(
        Type.Union(
          ["day", "week", "month", "year"].map((v) => Type.Literal(v)),
          { description: "Restrict to recent content" },
        ),
      ),
      domainFilter: Type.Optional(
        Type.Array(Type.String(), {
          description: 'Limit to domains (prefix with "-" to exclude)',
        }),
      ),
      provider: Type.Optional(
        Type.String({
          description:
            'Specific provider (openai, brave, exa, tavily, ...) or "all"; omit for auto fallback chain',
        }),
      ),
    }),
    execute: async (_toolCallId, rawParams) => {
      const params = rawParams as {
        query?: string;
        numResults?: number;
        recencyFilter?: "day" | "week" | "month" | "year";
        domainFilter?: string[];
        provider?: string;
      };
      const query = params.query?.trim();
      if (!query) throw new Error("query is required");

      const response = await searchWeb(query, {
        numResults: params.numResults,
        recencyFilter: params.recencyFilter,
        domainFilter: params.domainFilter,
        provider: params.provider,
      });
      const text = formatWebSearchResponse(response);

      return {
        content: [{ type: "text", text }],
        details: {
          query,
          provider: response.provider,
          count: response.results?.length ?? 0,
          results: response.results,
        },
      };
    },
  };

  const webFetchTool: AgentTool = {
    name: "web_fetch",
    label: "Web Fetch",
    description:
      "Fetch a URL and return readable markdown content. Handles regular pages (Readability " +
      "extraction), GitHub repos (cloned locally), PDFs (text extraction), and YouTube videos " +
      "(transcript). Use after web_search when you need page content.",
    parameters: Type.Object({
      url: Type.String({ description: "http(s) URL to fetch" }),
    }),
    execute: async (_toolCallId, rawParams) => {
      const params = rawParams as { url?: string };
      const target = params.url?.trim();
      if (!target) throw new Error("url is required");

      const result = await fetchWebPage(target);
      const body = result.title ? `# ${result.title}\n\n${result.content}` : result.content;
      const text = truncateToolOutput(body);

      return {
        content: [{ type: "text", text }],
        details: {
          url: result.url,
          contentType: result.mimeType,
          bytes: text.length,
          warning: result.error ?? undefined,
        },
      };
    },
  };

  return [webSearchTool, webFetchTool];
}
