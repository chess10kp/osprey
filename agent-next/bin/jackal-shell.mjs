#!/usr/bin/env node
// ────────────────────────────────────────────────────────────────────────────
// jackal-shell — scaffold and run the Jackal Ink TUI shell.
//
// Usage:
//   npx jackal-shell                    # run in current directory
//   npx jackal-shell /path/to/project   # run in specific project
//   npx jackal-shell --scaffold-only    # just create the scaffold, don't run
// ────────────────────────────────────────────────────────────────────────────

import { writeFileSync, existsSync, mkdirSync, cpSync } from "node:fs";
import { join, resolve } from "node:path";
import { execSync, spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const templateDir = join(__dirname, "..", "templates");

const args = process.argv.slice(2);
let scaffoldOnly = false;
let targetDir = process.cwd();

for (const arg of args) {
  if (arg === "--scaffold-only") { scaffoldOnly = true; }
  else if (arg === "--help" || arg === "-h") {
    console.log(`jackal-shell — Run the Jackal Ink TUI coding agent

Usage:
  npx jackal-shell [options] [directory]

Options:
  --scaffold-only   Create the scaffold without running
  --help, -h        Show this help

The shell is scaffolded in <directory>/.jac/jackal-shell/
with all dependencies pinned to compatible versions.`);
    process.exit(0);
  }
  else if (!arg.startsWith("-")) { targetDir = resolve(arg); }
}

const outDir = join(targetDir, ".jac", "jackal-shell");
const template = join(templateDir, "shell.mjs");

if (!existsSync(template)) {
  console.error(`Error: shell template not found at ${template}`);
  console.error("Make sure you're running from the jackal repo or have it installed.");
  process.exit(1);
}

// Scaffold
mkdirSync(outDir, { recursive: true });

const pkgJson = {
  name: "jackal-shell",
  private: true,
  type: "module",
  scripts: { start: "node shell.mjs" },
  dependencies: {
    ink: "^7.0.3",
    react: "^19.2.4",
    "@earendil-works/pi-coding-agent": "0.75.4",
  },
};

writeFileSync(join(outDir, "shell.mjs"), 
  require("fs").readFileSync(template, "utf-8"),
  "utf-8"
);
writeFileSync(
  join(outDir, "package.json"),
  JSON.stringify(pkgJson, null, 2) + "\n",
  "utf-8",
);

console.log(`✅ Shell scaffolded in ${outDir}`);

if (scaffoldOnly) {
  console.log(`\nTo run:
  cd ${outDir}
  npm install --ignore-scripts
  npm start`);
  process.exit(0);
}

// Install deps if needed
if (!existsSync(join(outDir, "node_modules"))) {
  console.log("📦 Installing dependencies...");
  try {
    execSync("npm install --ignore-scripts", {
      cwd: outDir,
      stdio: "inherit",
      timeout: 120_000,
    });
  } catch (err) {
    console.error("❌ npm install failed. Try running manually:");
    console.error(`   cd ${outDir} && npm install --ignore-scripts`);
    process.exit(1);
  }
}

// Run
console.log("🐺 Starting Jackal...\n");
const child = spawn("node", ["shell.mjs"], {
  cwd: outDir,
  stdio: "inherit",
  env: { ...process.env },
});

child.on("exit", (code) => process.exit(code ?? 0));
