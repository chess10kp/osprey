export interface CompletionContext {
  authStepKind: string;
  providers: string[];
  models: string[];
  authOptions: string[];
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

export function getSuggestions(input: string, ctx: CompletionContext): Suggestion[] {
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

  return sortAndMap(trimmed, COMMANDS);
}
