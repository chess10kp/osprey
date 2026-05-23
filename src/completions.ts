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

const COMMANDS = [
  "/help",
  "/login",
  "/logout",
  "/model",
  "/abort",
  "/clear",
  "/new",
  "/compact",
  "/usage",
  "/resume",
  "/rename",
  "/export",
  "/checkpoint",
  "/tasks",
  "/mcp",
  "/osp",
  "/agents",
  "/commands",
  "/jac-check",
  "/jac-doctor",
  "/fix",
  "/create",
  "/exit",
  "/cancel",
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

function getCurrentFileMention(input: string): { mention: string; start: number; end: number } | null {
  const pos = input.length;
  let start = -1;
  for (let i = pos - 1; i >= 0; i--) {
    const ch = input[i];
    if (ch === "@") {
      start = i;
      break;
    }
    if (ch === " " || ch === "\t" || ch === "\n") break;
  }
  if (start < 0) return null;

  let end = pos;
  for (let i = pos; i < input.length; i++) {
    const ch = input[i];
    if (ch === " " || ch === "\t" || ch === "\n" || ch === "@") break;
    end = i + 1;
  }

  const mention = input.slice(start + 1, end).replace(/:\d+(-\d+)?$/, "");
  return { mention, start, end };
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

function getFileSuggestions(input: string, filePaths: string[]): Suggestion[] {
  const mention = getCurrentFileMention(input);
  if (!mention) return [];

  const scored = [...new Set(filePaths)]
    .map((path) => ({ path, score: rankFile(mention.mention, path) }))
    .filter((x) => x.score >= 0)
    .sort((a, b) => b.score - a.score || a.path.localeCompare(b.path))
    .slice(0, 8);

  return scored.map(({ path }) => ({
    label: path,
    value: `${input.slice(0, mention.start)}@${path}${input.slice(mention.end)}`,
  }));
}

export function getSuggestions(input: string, ctx: CompletionContext): Suggestion[] {
  const fileSuggestions = getFileSuggestions(input, ctx.filePaths ?? []);
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

  return sortAndMap(trimmed, COMMANDS);
}
