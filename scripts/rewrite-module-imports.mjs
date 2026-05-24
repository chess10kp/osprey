#!/usr/bin/env node
/**
 * Rewrites TypeScript import paths after src/ module reorganization.
 * Run once after git mv; safe to delete afterward.
 */
import { readFileSync, writeFileSync, readdirSync, statSync } from "node:fs";
import { join, dirname, relative } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(fileURLToPath(new URL(".", import.meta.url)), "..");
const srcRoot = join(root, "src");

/** Canonical module stem -> path under src/ (no extension) */
const MODULES = {
  adapter: "core/adapter",
  store: "core/store",
  bridge: "core/bridge",
  "ui-context": "core/ui-context",
  "auth-flow": "auth/auth-flow",
  "auth-actions": "auth/auth-actions",
  auth: "auth/auth",
  completions: "ui/completions",
  run: "cli/run",
  session: "session/session",
  "session-index": "session/session-index",
  "agent-session": "session/agent-session",
  "auto-compact": "session/auto-compact",
  tools: "agent/tools",
  "agent-tool": "agent/agent-tool",
  "task-tools": "agent/task-tools",
  "tool-approval": "agent/tool-approval",
  "tool-output-limit": "agent/tool-output-limit",
  "mcp-client": "agent/mcp-client",
  "dev-mode": "agent/dev-mode",
  "system-prompt": "agent/system-prompt",
  "project-config": "config/project-config",
  "jac-cli": "jac/jac-cli",
  "jac-doctor": "jac/jac-doctor",
  "jac-types": "jac/jac-types",
  "jac-workflows": "jac/jac-workflows",
  "lsp-tools": "jac/lsp-tools",
  tasks: "workflow/tasks",
  checkpoints: "workflow/checkpoints",
  "context-input": "workflow/context-input",
  "context-usage": "workflow/context-usage",
  "custom-commands": "workflow/custom-commands",
  subagents: "orchestration/subagents",
  chains: "orchestration/chains",
  "subagent-runner": "orchestration/subagent-runner",
  frontmatter: "orchestration/frontmatter",
  "project-init": "project/project-init",
  "file-explorer": "project/file-explorer",
  "skill-index": "project/skill-index",
  "mermaid-render": "render/mermaid-render",
  index: "index",
};

function stemFromImport(spec) {
  const cleaned = spec.replace(/\.js$/, "");
  const base = cleaned.split("/").pop();
  return base;
}

function resolveCanonical(spec) {
  const cleaned = spec.replace(/\.js$/, "");
  // runtime/foo -> foo
  const runtimeMatch = cleaned.match(/(?:^|\/)runtime\/(.+)$/);
  if (runtimeMatch) {
    const stem = runtimeMatch[1];
    if (MODULES[stem]) return MODULES[stem];
  }
  const stem = stemFromImport(cleaned);
  if (MODULES[stem]) return MODULES[stem];
  return null;
}

function relativeImport(fromFile, canonicalPath) {
  const fromDir = dirname(fromFile);
  const toFile = join(srcRoot, `${canonicalPath}.js`);
  let rel = relative(fromDir, toFile).replace(/\\/g, "/");
  if (!rel.startsWith(".")) rel = `./${rel}`;
  return rel;
}

function rewriteFile(filePath) {
  let content = readFileSync(filePath, "utf8");
  const original = content;

  content = content.replace(
    /((?:import|export)\s+(?:type\s+)?(?:[\s\S]*?\sfrom\s+|))(['"])([^'"]+)(['"])/g,
    (match, prefix, q1, spec, q2) => {
      if (!spec.startsWith(".")) return match;
      const canonical = resolveCanonical(spec);
      if (!canonical) return match;
      const newSpec = relativeImport(filePath, canonical);
      return `${prefix}${q1}${newSpec}${q2}`;
    },
  );

  if (content !== original) {
    writeFileSync(filePath, content, "utf8");
    return true;
  }
  return false;
}

function walk(dir, out = []) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) walk(p, out);
    else if (p.endsWith(".ts")) out.push(p);
  }
  return out;
}

const targets = [
  ...walk(srcRoot),
  ...walk(join(root, "tests")).filter((p) => p.endsWith(".ts")),
];

let changed = 0;
for (const file of targets) {
  if (rewriteFile(file)) {
    changed++;
    console.log("updated:", relative(root, file));
  }
}
console.log(`\n${changed} file(s) updated`);
