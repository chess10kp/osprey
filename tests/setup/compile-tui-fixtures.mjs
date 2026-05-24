#!/usr/bin/env node
/**
 * Compile Jackal .cl.jac TUI components into tests/fixtures/tui/<stem>/ for render tests.
 * Skips gracefully when jac-ink (`jac tui`) is unavailable — writes manifest with compiled=false.
 */

import { execFileSync, spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { COMPONENTS, SHELL } from "./component-manifest.mjs";
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

function ensureMarkdownSupport(outDir, modulePath) {
  const code = fs.readFileSync(modulePath, "utf8");
  if (!/\bparseMarkdownParts\b/.test(code)) return;

  const src = path.join(JACKAL_ROOT, "templates/markdown.mjs");
  if (!fs.existsSync(src)) {
    throw new Error("templates/markdown.mjs missing — required for AssistantMessage fixtures");
  }
  fs.copyFileSync(src, path.join(outDir, "markdown.mjs"));
}

function postprocessModule(outDir, modulePath) {
  const fixScript = path.join(JACKAL_ROOT, "scripts/fix-tui-module.mjs");
  if (fs.existsSync(fixScript)) {
    execFileSync(process.execPath, [fixScript, modulePath], { stdio: "inherit" });
  }
  ensureMarkdownSupport(outDir, modulePath);
  execFileSync(process.execPath, ["--check", modulePath], { stdio: "pipe" });
}

function compileOne(jacBin, spec) {
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

  if (spec.stem === "shell") {
    const dedupe = path.join(JACKAL_ROOT, "scripts/dedupe-jac-runtime.mjs");
    if (fs.existsSync(dedupe)) {
      execFileSync(process.execPath, [dedupe, modulePath], { stdio: "inherit" });
    }
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

  const compiled = [];
  for (const spec of COMPONENTS) {
    console.log(`compiling ${spec.file} …`);
    compiled.push(compileOne(jacBin, spec));
  }
  console.log(`compiling ${SHELL.file} …`);
  compiled.push(compileOne(jacBin, SHELL));

  writeManifest(compiled);
  console.log(`compiled ${compiled.length} TUI fixture(s) into ${FIXTURES_ROOT}`);
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
