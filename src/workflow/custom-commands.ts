// Custom commands — load and expand .jackal/commands/*.md.
// File loading delegated to lib/jac/workflow/_custom_commands_toolchain.py via bridge.
// Parsing/expansion stays local for hot-path use.

import {
  bridgeLoadCustomCommands,
  bridgeLoadCustomCommandsSync,
} from "../jac/jac-bridge.js";

export interface CustomCommand {
  name: string;
  description: string;
  aliases: string[];
  parameters: string[];
  body: string;
  filePath: string;
}

export async function loadCustomCommandsAsync(cwd: string): Promise<CustomCommand[]> {
  return bridgeLoadCustomCommands(cwd);
}

export function loadCustomCommands(cwd: string): CustomCommand[] {
  return bridgeLoadCustomCommandsSync(cwd);
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
  options.parameters.forEach((key, i) => {
    const value = options.args[i] ?? "";
    out = out.replaceAll(`{{${key}}}`, value);
  });
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
  const commandName = (space === -1 ? body : body.slice(0, space)).toLowerCase();
  const args =
    space === -1
      ? []
      : body
        .slice(space + 1)
        .trim()
        .split(/\s+/)
        .filter(Boolean);

  const lookup = new Map<string, CustomCommand>();
  for (const cmd of commands) {
    lookup.set(cmd.name.toLowerCase(), cmd);
    for (const alias of cmd.aliases) {
      lookup.set(alias.toLowerCase(), cmd);
    }
  }

  const command = lookup.get(commandName);
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

export function tryExpandSlashCommand(
  text: string,
  cwd: string,
  commands?: CustomCommand[],
): string | null {
  const resolved = resolveCustomCommandInput(text, commands ?? loadCustomCommands(cwd));
  if (!resolved) return null;
  return expandCustomCommand(resolved.command, resolved.args, cwd);
}

export function formatCustomCommandCatalogFromCommands(commands: CustomCommand[]): string {
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

export function formatCustomCommandCatalog(cwd: string): string {
  return formatCustomCommandCatalogFromCommands(loadCustomCommands(cwd));
}

export function customCommandSlashNamesFromCommands(commands: CustomCommand[]): string[] {
  const names = new Set<string>();
  for (const cmd of commands) {
    names.add(`/${cmd.name}`);
    for (const alias of cmd.aliases) {
      names.add(`/${alias}`);
    }
  }
  return [...names].sort();
}

export function customCommandSlashNames(cwd: string): string[] {
  return customCommandSlashNamesFromCommands(loadCustomCommands(cwd));
}
