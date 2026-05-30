// Slash-command, @file, and model autocomplete — pure TS, no bridge.
//
// The completion catalog (file paths, commands, models) is loaded once at
// boot and cached.  Prefix matching runs in-process on every keystroke —
// no Python subprocess, no bridge, zero blocking latency.

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

// ── Built-in slash commands ──────────────────────────────────────────────────

const COMMANDS: { slash: string; description: string }[] = [
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
  { slash: "/diff", description: "terminal diff editor (git)" },
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

// ── Ranking helpers ──────────────────────────────────────────────────────────

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
  const seen = new Set<string>();
  const scored: [Suggestion, number][] = [];
  for (const v of values) {
    if (seen.has(v)) continue;
    seen.add(v);
    const s = rank(input, v);
    if (s >= 0) scored.push([{ label: v, value: v }, s]);
  }
  scored.sort((a, b) => b[1] - a[1] || a[0].value.localeCompare(b[0].value));
  return scored.slice(0, 8).map(([item]) => item);
}

function sortAndMapCommands(input: string, commands = COMMANDS): Suggestion[] {
  const scored: [Suggestion, number][] = [];
  for (const c of commands) {
    const s = rank(input, c.slash);
    if (s >= 0) {
      const label = `${c.slash}  ${c.description}`;
      scored.push([{ label, value: c.slash }, s]);
    }
  }
  scored.sort((a, b) => b[1] - a[1] || a[0].value.localeCompare(b[0].value));
  return scored.slice(0, 8).map(([item]) => item);
}

// ── File ranking ─────────────────────────────────────────────────────────────

function rankFile(query: string, filePath: string): number {
  const q = query.toLowerCase();
  const p = filePath.toLowerCase();
  const name = filePath.split("/").pop() ?? filePath;
  const n = name.toLowerCase();

  if (!q) return 50;
  if (p === q) return 1000;
  if (n === q) return 900;
  if (p.endsWith(q)) return 850;
  if (n.startsWith(q)) return 800;
  if (p.startsWith(q)) return 750;
  if (n.includes(q)) return 700;
  if (p.includes(q)) return 600;

  // fuzzy
  let pi = 0;
  let qi = 0;
  while (pi < p.length && qi < q.length) {
    if (p[pi] === q[qi]) qi++;
    pi++;
  }
  return qi === q.length ? 500 : -1;
}

function getCurrentFileMention(
  input: string,
  cursorPosition?: number,
): { mention: string; start: number; end: number; rangeSuffix: string } | null {
  const pos = cursorPosition ?? input.length;

  let start = -1;
  for (let i = pos - 1; i >= 0; i--) {
    const ch = input[i]!;
    if (ch === "@") { start = i; break; }
    if (ch === " " || ch === "\t" || ch === "\n") break;
  }
  if (start < 0) return null;

  let end = pos;
  for (let i = pos; i < input.length; i++) {
    const ch = input[i]!;
    if (ch === " " || ch === "\t" || ch === "\n" || ch === "@") break;
    end = i + 1;
  }

  const full = input.slice(start + 1, end);
  const rangeMatch = full.match(/^(.+?)(:\d+(?:-\d*)?)$/);
  const mention = rangeMatch ? rangeMatch[1]! : full;
  const rangeSuffix = rangeMatch ? rangeMatch[2]! : "";

  return { mention, start, end, rangeSuffix };
}

function getFileSuggestions(
  inputText: string,
  filePaths: string[],
  cursorPosition?: number,
): Suggestion[] {
  const mention = getCurrentFileMention(inputText, cursorPosition);
  if (!mention) return [];

  const { mention: query, start, end, rangeSuffix } = mention;

  const seen = new Set<string>();
  const scored: [Suggestion, number][] = [];
  for (const fp of filePaths) {
    if (seen.has(fp)) continue;
    seen.add(fp);
    const s = rankFile(query, fp);
    if (s >= 0) {
      scored.push([
        {
          label: fp,
          value: inputText.slice(0, start) + "@" + fp + rangeSuffix + inputText.slice(end),
        },
        s,
      ]);
    }
  }
  scored.sort((a, b) => b[1] - a[1] || a[0].label.localeCompare(b[0].label));
  return scored.slice(0, 8).map(([item]) => item);
}

// ── Main entry point (pure TS, zero subprocess) ──────────────────────────────

export function getSuggestions(
  input: string,
  ctx: CompletionContext,
  cursorPosition?: number,
): Suggestion[] {
  const {
    authStepKind = "",
    providers = [],
    models = [],
    authOptions = [],
    filePaths = [],
    customCommands = [],
  } = ctx;

  // File suggestions first
  const fileSuggs = getFileSuggestions(input, filePaths, cursorPosition);
  if (fileSuggs.length > 0) return fileSuggs;

  const trimmed = input.trim();

  if (authStepKind === "select") return sortAndMap(trimmed, authOptions);
  if (authStepKind === "provider_picker") return sortAndMap(trimmed, providers);
  if (authStepKind === "model_picker") return sortAndMap(trimmed, models);

  if (!trimmed.startsWith("/")) return [];

  if (trimmed.startsWith("/login ")) {
    const q = trimmed.slice("/login ".length);
    return sortAndMap(q, providers).map((s) => ({ ...s, value: `/login ${s.value}` }));
  }
  if (trimmed.startsWith("/logout ")) {
    const q = trimmed.slice("/logout ".length);
    return sortAndMap(q, providers).map((s) => ({ ...s, value: `/logout ${s.value}` }));
  }
  if (trimmed.startsWith("/model ")) {
    const q = trimmed.slice("/model ".length);
    return sortAndMap(q, models).map((s) => ({ ...s, value: `/model ${s.value}` }));
  }

  if (customCommands.length > 0) {
    const customMatches = sortAndMap(trimmed, customCommands);
    if (customMatches.length > 0) return customMatches;
  }

  return sortAndMapCommands(trimmed);
}
