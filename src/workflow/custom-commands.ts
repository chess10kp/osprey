import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join, relative, resolve } from "node:path";
import {
  frontmatterString,
  frontmatterStringList,
  parseFrontmatter,
} from "../orchestration/frontmatter.js";

export interface CustomCommand {
  /** Slash name, e.g. review or refactor:dry */
  name: string;
  description: string;
  aliases: string[];
  parameters: string[];
  body: string;
  filePath: string;
}

function findCommandsRoot(cwd: string): string | null {
  let cur = resolve(cwd);
  while (true) {
    const candidate = join(cur, ".jackal", "commands");
    if (existsSync(candidate)) return candidate;
    const parent = resolve(cur, "..");
    if (parent === cur) return null;
    cur = parent;
  }
}

function commandNameFromPath(commandsRoot: string, filePath: string): string {
  const rel = relative(commandsRoot, filePath).replace(/\\/g, "/");
  const withoutExt = rel.replace(/\.md$/i, "");
  const parts = withoutExt.split("/");
  if (parts.length === 1) return parts[0]!;
  return `${parts.slice(0, -1).join(":")}:${parts[parts.length - 1]}`;
}

function listCommandFiles(dir: string): string[] {
  const out: string[] = [];

  function walk(current: string): void {
    let entries;
    try {
      entries = readdirSync(current, { withFileTypes: true }).sort((a, b) =>
        a.name.localeCompare(b.name),
      );
    } catch {
      return;
    }

    for (const entry of entries) {
      const filePath = join(current, entry.name);
      if (entry.isDirectory()) {
        if (entry.name === "resources") continue;
        walk(filePath);
        continue;
      }
      if (entry.isFile() && entry.name.endsWith(".md")) {
        out.push(filePath);
      }
    }
  }

  walk(dir);
  return out;
}

function loadCommandFile(commandsRoot: string, filePath: string): CustomCommand | null {
  let content: string;
  try {
    content = readFileSync(filePath, "utf-8");
  } catch {
    return null;
  }

  const { frontmatter, body } = parseFrontmatter(content);
  const name = commandNameFromPath(commandsRoot, filePath);
  const description = frontmatterString(frontmatter.description)?.trim() ?? name;

  return {
    name,
    description,
    aliases: frontmatterStringList(frontmatter.aliases),
    parameters: frontmatterStringList(frontmatter.parameters),
    body: body.trim(),
    filePath,
  };
}

export function loadCustomCommands(cwd: string): CustomCommand[] {
  const root = findCommandsRoot(cwd);
  if (!root) return [];

  const byName = new Map<string, CustomCommand>();
  for (const filePath of listCommandFiles(root)) {
    const cmd = loadCommandFile(root, filePath);
    if (!cmd) continue;
    byName.set(cmd.name, cmd);
    for (const alias of cmd.aliases) {
      byName.set(alias, cmd);
    }
  }

  const unique = new Map<string, CustomCommand>();
  for (const cmd of byName.values()) {
    unique.set(cmd.name, cmd);
  }
  return [...unique.values()].sort((a, b) => a.name.localeCompare(b.name));
}

export function expandCommandTemplate(
  template: string,
  options: {
    command: string;
    args: string[];
    parameters: string[];
    cwd: string;
  },
): string {
  let out = template;

  for (let i = 0; i < options.parameters.length; i++) {
    const key = options.parameters[i]!;
    const value = options.args[i] ?? "";
    out = out.replaceAll(`{{${key}}}`, value);
  }

  out = out.replaceAll("{{cwd}}", options.cwd);
  out = out.replaceAll("{{command}}", options.command);
  out = out.replaceAll("{{args}}", options.args.join(" "));

  return out.trim();
}

export function resolveCustomCommandInput(
  input: string,
  commands: CustomCommand[],
): { command: CustomCommand; args: string[] } | null {
  const trimmed = input.trim();
  if (!trimmed.startsWith("/")) return null;

  const body = trimmed.slice(1);
  const space = body.indexOf(" ");
  const cmdName = (space === -1 ? body : body.slice(0, space)).toLowerCase();
  const args = space === -1 ? [] : body.slice(space + 1).trim().split(/\s+/).filter(Boolean);

  const lookup = new Map<string, CustomCommand>();
  for (const cmd of commands) {
    lookup.set(cmd.name.toLowerCase(), cmd);
    for (const alias of cmd.aliases) {
      lookup.set(alias.toLowerCase(), cmd);
    }
  }

  const command = lookup.get(cmdName);
  if (!command) return null;
  return { command, args };
}

export function expandCustomCommand(
  command: CustomCommand,
  args: string[],
  cwd: string,
): string {
  return expandCommandTemplate(command.body, {
    command: command.name,
    args,
    parameters: command.parameters,
    cwd,
  });
}

export function tryExpandSlashCommand(text: string, cwd: string): string | null {
  const commands = loadCustomCommands(cwd);
  const resolved = resolveCustomCommandInput(text, commands);
  if (!resolved) return null;
  return expandCustomCommand(resolved.command, resolved.args, cwd);
}

export function formatCustomCommandCatalog(cwd: string): string {
  const commands = loadCustomCommands(cwd);
  if (commands.length === 0) {
    return "No custom commands found in .jackal/commands/.";
  }

  const lines = ["Custom commands:", ""];
  for (const cmd of commands) {
    const aliasText = cmd.aliases.length > 0 ? ` (aliases: ${cmd.aliases.join(", ")})` : "";
    lines.push(`- /${cmd.name}${aliasText} — ${cmd.description}`);
  }
  return lines.join("\n");
}

export function customCommandSlashNames(cwd: string): string[] {
  const names = new Set<string>();
  for (const cmd of loadCustomCommands(cwd)) {
    names.add(`/${cmd.name}`);
    for (const alias of cmd.aliases) {
      names.add(`/${alias}`);
    }
  }
  return [...names].sort();
}
