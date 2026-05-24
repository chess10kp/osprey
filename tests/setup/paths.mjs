import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

export const JACKAL_ROOT = path.resolve(__dirname, "../..");
export const FIXTURES_ROOT = path.join(JACKAL_ROOT, "tests/fixtures/tui");
export const MANIFEST_PATH = path.join(FIXTURES_ROOT, "manifest.json");
export const SKIP_PATH = path.join(FIXTURES_ROOT, ".skip");

export function fixtureDir(stem) {
  return path.join(FIXTURES_ROOT, stem);
}

export function fixtureModule(stem) {
  return path.join(fixtureDir(stem), "module.mjs");
}
