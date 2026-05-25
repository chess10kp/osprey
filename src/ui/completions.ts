import { getCurrentFileMention } from "../workflow/file-mention-parser.js";

export interface CompletionContext {
  authStepKind: string;
  providers: string[];
  models: string[];
  authOptions: string[];
  filePaths?: string[];
  customCommands?: string[];
}

export interface Suggestion {
  label: string;
  value: string;
}

interface CommandEntry {
  slash: string;
  description: string;
}

const COMMANDS: CommandEntry[] = [
  { slash: "/help", description: "toggle help panel" },
  { slash: "/login", description: "start auth flow" },
  { slash: "/logout", description: "logout provider" },
  { slash: "/model", description: "open model picker or set" },
  { slash: "/abort", description: "cancel active run" },
  { slash: "/clear", description: "new session" },
  { slash: "/new", description: "new session" },
  { slash: "/compact", description: "compact context" },
  { slash: "/usage", description: "context utilization" },
  { slash: "/resume", description: "load prior session" },
  { slash: "/rename", description: "rename current session" },
  { slash: "/export", description: "export session to file" },
  { slash: "/checkpoint", description: "snapshot files + chat" },
  { slash: "/tasks", description: "task list" },
  { slash: "/mcp", description: "MCP connection status" },
  { slash: "/osp", description: "OSP graph design" },
  { slash: "/plan", description: "generate implementation plan" },
  { slash: "/agents", description: "list subagents" },
  { slash: "/commands", description: "list custom commands" },
  { slash: "/skills", description: "list agent skills" },
  { slash: "/init", description: "generate AGENTS.md" },
  { slash: "/jac-check", description: "run jac check" },
  { slash: "/jac-doctor", description: "environment diagnostics" },
  { slash: "/jac-test", description: "run jac test" },
  { slash: "/jac-format", description: "format .jac files" },
  { slash: "/jac explain", description: "explain file/walker/error/graph" },
  { slash: "/jac convert-python", description: "convert Python to Jac" },
  { slash: "/jac review-idioms", description: "review Jac idioms" },
  { slash: "/jac create", description: "run jac create template" },
  { slash: "/fix", description: "jac check/fix loop" },
  { slash: "/create", description: "list jac templates" },
  { slash: "/explorer", description: "multi-select @file context" },
  { slash: "/context-max", description: "set/show max context tokens" },
  { slash: "/jac diagram-to-model", description: "diagram → OSP model" },
  { slash: "/refactor", description: "refactor code" },
  { slash: "/exit", description: "quit" },
  { slash: "/cancel", description: "cancel auth flow" },
];

function rank(input: string, value: string): number {
  const i = input.toLowerCase();
  const v = value.toLowerCase();
  if (!i) return 0;
  if (v === i) return 100;
  if (v.startsWith(i)) return 80;
  if (v.includes(i)) return 50;
  return -1;
}

function sortAndMap(input: string, values: string[]): Suggestion[] {
  return [...new Set(values)]
    .map((v) => ({ v, s: rank(input, v) }))
    .filter((x) => x.s >= 0)
    .sort((a, b) => b.s - a.s || a.v.localeCompare(b.v))
    .slice(0, 8)
    .map((x) => ({ label: x.v, value: x.v }));
}

function sortAndMapCommands(input: string, commands: CommandEntry[]): Suggestion[] {
  return commands
    .map((c) => ({ c, s: rank(input, c.slash) }))
    .filter((x) => x.s >= 0)
    .sort((a, b) => b.s - a.s || a.c.slash.localeCompare(b.c.slash))
    .slice(0, 8)
    .map((x) => ({ label: `${x.c.slash}  ${x.c.description}`, value: x.c.slash }));
}

function rankFile(query: string, filePath: string): number {
  const q = query.toLowerCase();
  const p = filePath.toLowerCase();
  const name = filePath.split("/").pop() ?? "";
  const n = name.toLowerCase();

  if (!q) return 50;
  if (p === q) return 1000;
  if (n === q) return 900;
  if (p.endsWith(q)) return 850;
  if (n.startsWith(q)) return 800;
  if (p.startsWith(q)) return 750;
  if (n.includes(q)) return 700;
  if (p.includes(q)) return 600;

  let pi = 0;
  let qi = 0;
  while (pi < p.length && qi < q.length) {
    if (p[pi] === q[qi]) qi++;
    pi++;
  }
  return qi === q.length ? 500 : -1;
}

function getFileSuggestions(
  input: string,
  filePaths: string[],
  cursorPosition?: number,
): Suggestion[] {
  const mention = getCurrentFileMention(input, cursorPosition);
  if (!mention) return [];

  const scored = [...new Set(filePaths)]
    .map((path) => ({ path, score: rankFile(mention.mention, path) }))
    .filter((x) => x.score >= 0)
    .sort((a, b) => b.score - a.score || a.path.localeCompare(b.path))
    .slice(0, 8);

  return scored.map(({ path }) => ({
    label: path,
    value: `${input.slice(0, mention.start)}@${path}${mention.rangeSuffix}${input.slice(mention.end)}`,
  }));
}

export function getSuggestions(
  input: string,
  ctx: CompletionContext,
  cursorPosition?: number,
): Suggestion[] {
  const fileSuggestions = getFileSuggestions(input, ctx.filePaths ?? [], cursorPosition);
  if (fileSuggestions.length > 0) {
    return fileSuggestions;
  }

  const trimmed = input.trim();

  if (ctx.authStepKind === "select") {
    return sortAndMap(trimmed, ctx.authOptions);
  }

  if (ctx.authStepKind === "provider_picker") {
    return sortAndMap(trimmed, ctx.providers);
  }

  if (ctx.authStepKind === "model_picker") {
    return sortAndMap(trimmed, ctx.models);
  }

  if (!trimmed.startsWith("/")) return [];

  if (trimmed.startsWith("/login ")) {
    const q = trimmed.slice("/login ".length);
    return sortAndMap(q, ctx.providers).map((s) => ({ ...s, value: `/login ${s.value}` }));
  }

  if (trimmed.startsWith("/logout ")) {
    const q = trimmed.slice("/logout ".length);
    return sortAndMap(q, ctx.providers).map((s) => ({ ...s, value: `/logout ${s.value}` }));
  }

  if (trimmed.startsWith("/model ")) {
    const q = trimmed.slice("/model ".length);
    return sortAndMap(q, ctx.models).map((s) => ({ ...s, value: `/model ${s.value}` }));
  }

  const custom = ctx.customCommands ?? [];
  if (custom.length > 0) {
    const customMatches = sortAndMap(trimmed, custom);
    if (customMatches.length > 0) return customMatches;
  }

  return sortAndMapCommands(trimmed, COMMANDS);
}
