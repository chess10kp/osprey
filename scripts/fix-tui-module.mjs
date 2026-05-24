#!/usr/bin/env node
// Post-process jac-ink module.mjs: merge duplicate imports, inline theme, add missing symbols.

import fs from "node:fs";

const path = process.argv[2];
if (!path) {
  console.error("usage: fix-tui-module.mjs <module.mjs>");
  process.exit(1);
}

const importLineRe = /^import\s+\{([^}]+)\}\s+from\s+(["'])([^"']+)\2;\s*$/;

let src = fs.readFileSync(path, "utf8");
const lines = src.split("\n");

/** @type {Map<string, Set<string>>} */
const merged = new Map();
/** @type {string[]} */
const preamble = [];
/** @type {string[]} */
const body = [];
/** @type {string[] | null} */
let themeBlock = null;

let phase = "preamble";

for (let i = 0; i < lines.length; i++) {
  const line = lines[i];
  const importMatch = line.match(importLineRe);

  if (line.includes("// Imported .jac module: .theme")) {
    themeBlock = [];
    i += 1;
    while (i < lines.length) {
      const tl = lines[i];
      if (tl.startsWith("// Imported .jac module:") || tl.startsWith("// Client module:")) {
        i -= 1;
        break;
      }
      if (tl.trim() === "" && themeBlock.length > 0) {
        break;
      }
      themeBlock.push(tl);
      i += 1;
    }
    continue;
  }

  if (importMatch) {
    let spec = importMatch[3];
    if (spec === "./theme.js") {
      continue;
    }
    if (spec === "../markdown.mjs") {
      spec = "./markdown.mjs";
    }
    if (!merged.has(spec)) merged.set(spec, new Set());
    for (const part of importMatch[1].split(",")) {
      const name = part.trim();
      if (name) merged.get(spec).add(name);
    }
    continue;
  }

  if (phase === "preamble" && line.startsWith("// Imported .jac module:")) {
    phase = "body";
  }

  if (phase === "preamble") {
    preamble.push(line);
  } else {
    body.push(line);
  }
}

const code = [...preamble, ...body].join("\n");

if (/\bStatic\b/.test(code)) {
  if (!merged.has("ink")) merged.set("ink", new Set());
  merged.get("ink").add("Static");
}
if (/\bSpinner\b/.test(code)) {
  if (!merged.has("@inkjs/ui")) merged.set("@inkjs/ui", new Set());
  merged.get("@inkjs/ui").add("Spinner");
}
if (/\bTextInput\b/.test(code)) {
  if (!merged.has("@inkjs/ui")) merged.set("@inkjs/ui", new Set());
  merged.get("@inkjs/ui").add("TextInput");
}
for (const sym of ["Box", "Text", "useInput"]) {
  if (new RegExp(`\\b${sym}\\b`).test(code)) {
    if (!merged.has("ink")) merged.set("ink", new Set());
    merged.get("ink").add(sym);
  }
}

const importLines = [];
const order = [
  "./runtime_shim.mjs",
  "./jac_runtime_shim.mjs",
  "./jac_builtin_runtime.mjs",
  "./markdown.mjs",
  "ink",
  "@inkjs/ui",
  "./jac_pi_runtime_shim.mjs",
];
const seen = new Set();

for (const spec of order) {
  const names = merged.get(spec);
  if (!names || names.size === 0) continue;
  importLines.push(`import { ${[...names].sort().join(", ")} } from "${spec}";`);
  seen.add(spec);
}

for (const [spec, names] of merged) {
  if (seen.has(spec) || names.size === 0) continue;
  importLines.push(`import { ${[...names].sort().join(", ")} } from "${spec}";`);
}

const themeLines = themeBlock ?? [];
let out = [
  ...preamble.filter((l) => !importLineRe.test(l)),
  ...importLines,
  ...themeLines,
  "",
  ...body.filter((l) => !importLineRe.test(l)),
].join("\n");

// jac2ink: for-loops over enumerate sometimes omit closing brace before return.
out = out.replace(
  /(rows\.push\(__jacJsx\(Text, \{"color": "cyan", "bold": is_sel\}, \[\(icon \+ label\)\]\)\);\n\s*)(return __jacJsx\(Box, \{"flexDirection": "column", "paddingX": 1\}, \[__jacJsx\(Text, \{"dimColor": true\}, \["Completions:"\]\), rows\]\);)/g,
  "$1  }\n  $2",
);
out = out.replace(
  /(rows\.push\(__jacJsx\(Text, \{"bold": is_cur, "color": \(is_cur \? "cyan" : "white"\)\}, \[\(\(\(icon \+ mark\) \+ " "\) \+ String\(f\)\)\]\)\);\n\s*)(return __jacJsx\(Box, \{"flexDirection": "column", "borderStyle": "round", "borderColor": "blue")/g,
  "$1  }\n  $2",
);

// jac2ink: enumerate + JSX key= emits [key, f] but body still references i.
out = out.replace(
  /const \[key, f\] = _item;\n(\s*)rows\.push\(__jacJsx\(TranscriptRow, \{"key": \("f-" \+ String\(i\)\)/g,
  "const [key, f] = _item;\n$1rows.push(__jacJsx(TranscriptRow, {\"key\": (\"row-\" + String(key))",
);

// jac2ink: "\u25b8" in source double-escapes to literal "\\u25b8" in emitted JS.
out = out.replace(/"\\\\u25b8 "/g, '"\\u25b8 "');

fs.writeFileSync(path, out);
console.error(`fix-tui-module: merged ${importLines.length} import line(s) in ${path}`);
