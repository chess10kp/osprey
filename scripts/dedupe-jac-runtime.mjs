#!/usr/bin/env node
// Remove duplicate `const _jac = { ... };` blocks emitted when jac-ink bundles
// multiple .cl.jac imports into one module.mjs. Keep the first runtime only.

import fs from "node:fs";

const path = process.argv[2];
if (!path) {
  console.error("usage: dedupe-jac-runtime.mjs <module.mjs>");
  process.exit(1);
}

const marker = "const _jac = {";
let src = fs.readFileSync(path, "utf8");

function skipRuntimeBlock(text, startIdx) {
  let pos = startIdx + marker.length;
  let depth = 1;
  while (pos < text.length && depth > 0) {
    const ch = text[pos];
    if (ch === "{") depth += 1;
    else if (ch === "}") depth -= 1;
    pos += 1;
  }
  while (pos < text.length && /[\s;]/.test(text[pos])) pos += 1;
  return pos;
}

let first = src.indexOf(marker);
if (first === -1) process.exit(0);

let cursor = skipRuntimeBlock(src, first);
let removed = 0;

while (true) {
  const next = src.indexOf(marker, cursor);
  if (next === -1) break;
  const end = skipRuntimeBlock(src, next);
  src = src.slice(0, next) + src.slice(end);
  removed += 1;
  cursor = next;
}

if (removed > 0) {
  fs.writeFileSync(path, src);
  console.error(`dedupe-jac-runtime: removed ${removed} duplicate _jac block(s) from ${path}`);
}
