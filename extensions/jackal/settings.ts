// ────────────────────────────────────────────────────────────────────────────
// Jackal settings management — read/write jackal/settings.json, manage
// subagent model overrides, provide tab completion and TUI model picker.
//
// These operate on PI_CODING_AGENT_DIR (set by jackal.sh) so they never touch
// the user's global ~/.pi/ config.
// ────────────────────────────────────────────────────────────────────────────

import type { Api, Model } from "@earendil-works/pi-ai";
import type { ExtensionCommandContext, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { getSelectListTheme } from "@earendil-works/pi-coding-agent";
import { readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { Container, SelectList, Text } from "@earendil-works/pi-tui";

// ──── Settings file I/O ──────────────────────────────────────────────────

/** Resolve the path to jackal/settings.json (requires PI_CODING_AGENT_DIR). */
export function resolveJackalSettingsPath(): string | null {
  const base = process.env.PI_CODING_AGENT_DIR?.trim();
  if (!base) return null;
  return join(base, "settings.json");
}

/** Read and parse jackal/settings.json. Returns {data} or {data:null, error}. */
export function readJackalSettingsParsed(): { data: Record<string, unknown> | null; error?: string } {
  const path = resolveJackalSettingsPath();
  if (!path) {
    return { data: null, error: "PI_CODING_AGENT_DIR is not set (run via jackal.sh)." };
  }
  try {
    const text = readFileSync(path, "utf8");
    const data = JSON.parse(text) as Record<string, unknown>;
    return { data };
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    return { data: null, error: `${path}: ${msg}` };
  }
}

/** Write settings.json atomically (write to tmp, rename). */
export function writeJackalSettingsAtomic(data: Record<string, unknown>): { ok: boolean; error?: string } {
  const path = resolveJackalSettingsPath();
  if (!path) return { ok: false, error: "PI_CODING_AGENT_DIR is not set (run via jackal.sh)." };
  const tmp = `${path}.tmp.${process.pid}`;
  const text = `${JSON.stringify(data, null, 2)}\n`;
  try {
    writeFileSync(tmp, text, "utf8");
    renameSync(tmp, path);
    return { ok: true };
  } catch (e) {
    try {
      unlinkSync(tmp);
    } catch {
      /* ignore */
    }
    return { ok: false, error: e instanceof Error ? e.message : String(e) };
  }
}

// ──── Subagent model overrides ───────────────────────────────────────────

/** Format a Model object into a `provider/id` spec string. */
export function modelSpecFromRegistryModel(model: Model<Api>): string {
  return `${model.provider}/${model.id}`;
}

/** Describe current subagent model overrides for display. */
export function describeSubagentOverrides(settings: Record<string, unknown>): string {
  const sub = settings.subagents as Record<string, unknown> | undefined;
  const agentOverrides = sub?.agentOverrides as Record<string, Record<string, unknown>> | undefined;
  if (!agentOverrides || Object.keys(agentOverrides).length === 0) {
    return "No subagents.agentOverrides in jackal/settings.json.";
  }
  const lines = ["subagents.agentOverrides:", ""];
  for (const name of Object.keys(agentOverrides).sort()) {
    const o = agentOverrides[name]!;
    const model = o.model != null ? String(o.model) : "(default)";
    const thinking = o.thinking != null ? String(o.thinking) : "";
    lines.push(`  ${name}: model=${model}${thinking ? ` thinking=${thinking}` : ""}`);
  }
  lines.push("");
  lines.push("Usage: /subagent-model <agent> <provider/model-id>");
  lines.push("       /subagent-model <agent> clear   — remove model pin");
  lines.push("       /subagent-model <agent>         — pick model (TUI)");
  lines.push("");
  lines.push("Type the subagent name yourself (e.g. scout, worker, context-builder).");
  lines.push("Tab completion only suggests models after: <agent><space>");
  return lines.join("\n");
}

/** Set (or overwrite) the model pin for a subagent in settings.json. */
export function setSubagentModelPin(
  agent: string,
  modelSpec: string,
): { ok: boolean; error?: string } {
  const path = resolveJackalSettingsPath();
  if (!path) return { ok: false, error: "PI_CODING_AGENT_DIR is not set (run via jackal.sh)." };

  const { data: parsed, error: readErr } = readJackalSettingsParsed();
  if (!parsed) return { ok: false, error: readErr || "Could not read settings.json" };

  const subagents = (parsed.subagents as Record<string, unknown> | undefined) ?? {};
  const agentOverrides = {
    ...((subagents.agentOverrides as Record<string, Record<string, unknown>> | undefined) ?? {}),
  };
  const prev = agentOverrides[agent] ?? {};
  agentOverrides[agent] = { ...prev, model: modelSpec };
  parsed.subagents = { ...subagents, agentOverrides };
  return writeJackalSettingsAtomic(parsed);
}

/** Remove the model pin for a subagent from settings.json. */
export function clearSubagentModelPin(agent: string): { ok: boolean; error?: string } {
  const path = resolveJackalSettingsPath();
  if (!path) return { ok: false, error: "PI_CODING_AGENT_DIR is not set (run via jackal.sh)." };

  const { data: parsed, error: readErr } = readJackalSettingsParsed();
  if (!parsed) return { ok: false, error: readErr || "Could not read settings.json" };

  const subagents = (parsed.subagents as Record<string, unknown> | undefined) ?? {};
  const agentOverrides = {
    ...((subagents.agentOverrides as Record<string, Record<string, unknown>> | undefined) ?? {}),
  };
  const entry = agentOverrides[agent];
  if (!entry) {
    return { ok: true };
  }
  const nextEntry = { ...entry };
  delete nextEntry.model;
  const remaining = Object.keys(nextEntry);
  if (remaining.length === 0) {
    delete agentOverrides[agent];
  } else {
    agentOverrides[agent] = nextEntry;
  }
  parsed.subagents = { ...subagents, agentOverrides };
  return writeJackalSettingsAtomic(parsed);
}

// ──── Tab completion for /subagent-model ─────────────────────────────

/** Captured ExtensionContext for model registry access during completions. */
let latestExtensionContext: ExtensionContext | null = null;

export function setLatestExtensionContext(ctx: ExtensionContext | null): void {
  latestExtensionContext = ctx;
}

/**
 * Provide tab completions for `/subagent-model <agent> <model-prefix>`. 
 * Only completes models (second argument); agent names are typed manually.
 */
export function subagentModelCompletions(
  argumentPrefix: string,
): { value: string; label: string }[] | null {
  const head = argumentPrefix.replace(/^\s+/, "");
  const sp = head.indexOf(" ");
  if (sp === -1) return null;

  const agentToken = head.slice(0, sp).trim();
  if (!agentToken || !/^[\w.-]+$/.test(agentToken)) return null;

  const modelPrefix = head.slice(sp + 1).trim().toLowerCase();
  if (!latestExtensionContext) return null;

  let models: Model<Api>[];
  try {
    models = latestExtensionContext.modelRegistry.getAvailable();
  } catch {
    return null;
  }

  const items: { value: string; label: string }[] = [];
  for (const m of models) {
    const spec = modelSpecFromRegistryModel(m);
    if (!spec.toLowerCase().includes(modelPrefix) && !m.name.toLowerCase().includes(modelPrefix))
      continue;
    items.push({ value: `${agentToken} ${spec}`, label: `${spec} — ${m.name}` });
  }
  return items.slice(0, 40);
}

/** Open an interactive TUI model picker for a subagent. */
export async function pickSubagentModelSpec(
  agent: string,
  ctx: ExtensionCommandContext,
): Promise<string | undefined> {
  if (!ctx.hasUI) return undefined;
  let models: Model<Api>[];
  try {
    models = ctx.modelRegistry.getAvailable();
  } catch {
    ctx.ui.notify("Could not read model registry.", "error");
    return undefined;
  }
  if (models.length === 0) {
    ctx.ui.notify("No models available with configured auth.", "warning");
    return undefined;
  }
  models = [...models].sort((a, b) => a.name.localeCompare(b.name));
  const items = models.map((m) => ({
    value: modelSpecFromRegistryModel(m),
    label: m.name,
    description: `${m.provider}/${m.id}`,
  }));

  return ctx.ui.custom<string | undefined>((tui, theme, _kb, done) => {
    const container = new Container();
    container.addChild(new Text(theme.fg("accent", theme.bold(`Model for subagent: ${agent}`)), 0, 0));
    container.addChild(new Text(theme.fg("dim", "↑/↓ navigate · Enter confirm · Esc cancel"), 0, 0));
    container.addChild(new Text("", 0, 0));

    const list = new SelectList(items, Math.min(15, Math.max(5, items.length)), getSelectListTheme());
    list.onSelect = (item) => {
      done(item.value);
    };
    list.onCancel = () => {
      done(undefined);
    };
    container.addChild(list);

    return {
      render(width: number) {
        return container.render(width);
      },
      invalidate() {
        container.invalidate();
      },
      handleInput(data: string) {
        list.handleInput(data);
        tui.requestRender();
      },
    };
  });
}
