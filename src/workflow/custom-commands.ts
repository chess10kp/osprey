// Custom commands — load and expand .jackal/commands/*.md.
// Delegated to lib/jac/workflow/_custom_commands_toolchain.py via bridge.

import {
  bridgeLoadCustomCommands,
  bridgeExpandCommandTemplate,
  bridgeResolveCustomCommandInput,
  bridgeTryExpandSlashCommand,
  bridgeFormatCustomCommandCatalog,
  bridgeCustomCommandSlashNames,
} from "../jac/jac-bridge.js";

export interface CustomCommand {
  name: string;
  description: string;
  aliases: string[];
  parameters: string[];
  body: string;
  filePath: string;
}

export function loadCustomCommands(cwd: string): CustomCommand[] {
  return bridgeLoadCustomCommands(cwd);
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
  return bridgeExpandCommandTemplate(
    template,
    options.command,
    options.args,
    options.parameters,
    options.cwd,
  );
}

export function resolveCustomCommandInput(
  input: string,
  commands: CustomCommand[],
): { command: CustomCommand; args: string[] } | null {
  const result = bridgeResolveCustomCommandInput(
    input,
    commands.map((c) => ({ name: c.name, aliases: c.aliases })),
  );
  if (!result) return null;
  // Find the actual CustomCommand object by name
  const cmdByName = new Map<string, CustomCommand>();
  for (const cmd of commands) {
    cmdByName.set(cmd.name.toLowerCase(), cmd);
    for (const alias of cmd.aliases) {
      cmdByName.set(alias.toLowerCase(), cmd);
    }
  }
  const rawCmd = result.command as { name?: string };
  const found = rawCmd?.name ? cmdByName.get(rawCmd.name.toLowerCase()) : undefined;
  if (!found) return null;
  return { command: found, args: result.args };
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
  return bridgeTryExpandSlashCommand(text, cwd);
}

export function formatCustomCommandCatalog(cwd: string): string {
  return bridgeFormatCustomCommandCatalog(cwd);
}

export function customCommandSlashNames(cwd: string): string[] {
  return bridgeCustomCommandSlashNames(cwd);
}
