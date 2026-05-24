#!/usr/bin/env node
/**
 * Compile templates/tui-test.cl.jac into tests/fixtures/tui/shell/ for render tests.
 * Single compile unit — same graph as production shell (markdown import, inlined components).
 * Skips gracefully when jac-ink (`jac tui`) is unavailable.
 */

import { execFileSync, spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { TUI_TEST } from "./component-manifest.mjs";
import {
  FIXTURES_ROOT,
  JACKAL_ROOT,
  MANIFEST_PATH,
  SKIP_PATH,
  fixtureDir,
} from "./paths.mjs";

function findJacBin() {
  const candidates = [
    process.env.JAC_BIN,
    path.join(JACKAL_ROOT, ".venv/bin/jac"),
    "jac",
  ].filter(Boolean);

  for (const bin of candidates) {
    try {
      execFileSync(bin, ["tui", "--help"], { stdio: "ignore" });
      return bin;
    } catch {
      // try next
    }
  }
  return null;
}

function copyRuntimeAssets(outDir) {
  const markdown = path.join(JACKAL_ROOT, "templates/markdown.mjs");
  if (!fs.existsSync(markdown)) {
    throw new Error("templates/markdown.mjs missing");
  }
  fs.copyFileSync(markdown, path.join(outDir, "markdown.mjs"));
}

function postprocessModule(outDir, modulePath) {
  const fixScript = path.join(JACKAL_ROOT, "scripts/fix-tui-module.mjs");
  if (fs.existsSync(fixScript)) {
    execFileSync(process.execPath, [fixScript, modulePath], { stdio: "inherit" });
  }
  copyRuntimeAssets(outDir);
  execFileSync(process.execPath, ["--check", modulePath], { stdio: "pipe" });
}

function compileTestBundle(jacBin) {
  const spec = TUI_TEST;
  const src = path.join(JACKAL_ROOT, spec.file);
  const out = fixtureDir(spec.stem);
  fs.rmSync(out, { recursive: true, force: true });
  fs.mkdirSync(out, { recursive: true });

  const result = spawnSync(
    jacBin,
    ["tui", src, "--out", out, "--no_run", "--quiet"],
    { cwd: JACKAL_ROOT, encoding: "utf8" },
  );

  if (result.status !== 0) {
    throw new Error(
      `jac tui failed for ${spec.file}: ${result.stderr || result.stdout || "unknown error"}`,
    );
  }

  const modulePath = path.join(out, "module.mjs");
  if (!fs.existsSync(modulePath)) {
    throw new Error(`missing module.mjs after compiling ${spec.file}`);
  }

  postprocessModule(out, modulePath);

  const code = fs.readFileSync(modulePath, "utf8");
  if (code.includes("Could not compile")) {
    throw new Error(`compile warning in ${spec.file} — submodule failed to emit`);
  }

  for (const name of spec.exports) {
    if (!new RegExp(`function ${name}\\(`).test(code)) {
      throw new Error(`${spec.file}: expected export function ${name} missing in module.mjs`);
    }
  }

  return { stem: spec.stem, exports: spec.exports };
}

function writeSkip(reason) {
  fs.mkdirSync(FIXTURES_ROOT, { recursive: true });
  fs.writeFileSync(
    MANIFEST_PATH,
    JSON.stringify(
      {
        compiled: false,
        reason,
        compiledAt: new Date().toISOString(),
      },
      null,
      2,
    ),
  );
  fs.writeFileSync(SKIP_PATH, `${reason}\n`);
  console.warn(`jackal tui tests: skipped fixture compile — ${reason}`);
}

function writeManifest(compiled) {
  fs.mkdirSync(FIXTURES_ROOT, { recursive: true });
  fs.writeFileSync(
    MANIFEST_PATH,
    JSON.stringify(
      {
        compiled: true,
        compiledAt: new Date().toISOString(),
        components: compiled,
      },
      null,
      2,
    ),
  );
  if (fs.existsSync(SKIP_PATH)) fs.unlinkSync(SKIP_PATH);
}

export function compileTuiFixtures() {
  const jacBin = findJacBin();
  if (!jacBin) {
    writeSkip("jac tui not available (install jac-ink — see scripts/setup-jac-ink.sh)");
    return false;
  }

  console.log(`compiling ${TUI_TEST.file} …`);
  const compiled = compileTestBundle(jacBin);

  writeManifest([compiled]);
  console.log(`compiled TUI test bundle into ${fixtureDir(TUI_TEST.stem)}`);
  return true;
}

const isMain =
  process.argv[1] &&
  path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url));

if (isMain) {
  try {
    const ok = compileTuiFixtures();
    if (!ok) process.exit(0);
  } catch (err) {
    writeSkip(err instanceof Error ? err.message : String(err));
    process.exit(1);
  }
}
