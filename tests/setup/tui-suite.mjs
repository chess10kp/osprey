import fs from "node:fs";
import { afterEach, beforeEach } from "vitest";
import { MANIFEST_PATH } from "./paths.mjs";

export function loadManifest() {
  if (!fs.existsSync(MANIFEST_PATH)) {
    return { compiled: false, reason: "manifest missing" };
  }
  return JSON.parse(fs.readFileSync(MANIFEST_PATH, "utf8"));
}

export const manifest = loadManifest();
export const canRunTui = manifest.compiled === true;

/** Nanocoder-style terminal width control for layout tests. */
export function useTerminalWidth(defaultWidth = 100) {
  let originalColumns;

  beforeEach(() => {
    originalColumns = process.stdout.columns;
    process.stdout.columns = defaultWidth;
  });

  afterEach(() => {
    process.stdout.columns = originalColumns;
  });

  return {
    setWidth(cols) {
      process.stdout.columns = cols;
    },
  };
}

export const noop = () => {};

export const defaultUserInputProps = {
  input_text: "",
  placeholder: "/ commands, ! bash",
  completions: [],
  completion_index: 0,
  disabled: false,
  on_change: noop,
  on_submit: noop,
};
