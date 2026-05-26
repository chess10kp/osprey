import { bridgeGetSuggestions } from "../jac/jac-bridge.js";

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

export function getSuggestions(
  input: string,
  ctx: CompletionContext,
  cursorPosition?: number,
): Suggestion[] {
  return bridgeGetSuggestions({
    inputText: input,
    authStepKind: ctx.authStepKind,
    providers: ctx.providers,
    models: ctx.models,
    authOptions: ctx.authOptions,
    filePaths: ctx.filePaths,
    customCommands: ctx.customCommands,
    cursorPosition,
  });
}
