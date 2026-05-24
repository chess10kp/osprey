import fs from "node:fs";
import { describe, expect, it } from "vitest";
import { TUI_TEST } from "../setup/component-manifest.mjs";
import { FIXTURES_ROOT, MANIFEST_PATH, fixtureModule } from "../setup/paths.mjs";

function loadManifest() {
  if (!fs.existsSync(MANIFEST_PATH)) {
    return { compiled: false, reason: "manifest missing — run npm run test:tui:compile" };
  }
  return JSON.parse(fs.readFileSync(MANIFEST_PATH, "utf8"));
}

const manifest = loadManifest();
const canRun = manifest.compiled === true;

describe.skipIf(!canRun)("TUI compile smoke", () => {
  it("manifest marks fixtures as compiled", () => {
    expect(manifest.compiled).toBe(true);
    expect(fs.existsSync(FIXTURES_ROOT)).toBe(true);
  });

  for (const spec of [TUI_TEST]) {
    it(`${spec.file} emits expected symbols`, () => {
      const modulePath = fixtureModule(spec.stem);
      expect(fs.existsSync(modulePath)).toBe(true);

      const code = fs.readFileSync(modulePath, "utf8");
      expect(code).not.toContain("Could not compile");

      for (const name of spec.exports) {
        expect(code).toMatch(new RegExp(`function ${name}\\(`));
      }
    });
  }
});

if (!canRun) {
  describe("TUI compile smoke (skipped)", () => {
    it("documents why fixtures were not compiled", () => {
      expect(manifest.reason ?? "jac tui unavailable").toBeTruthy();
    });
  });
}
