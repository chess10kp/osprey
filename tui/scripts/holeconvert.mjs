#!/usr/bin/env bun
// stdin: {js, path}  ->  stdout: {ok, jac, holeCount, declHoleCount, keptCount}
// Converts one JS/TS source to Jac with hole-emission on (LLM-cleanup pipeline).
// Jackal-local copy: bridge resolved relative to this script (../js2jac/).
import { createRequire } from "module";
import { fileURLToPath } from "url";
import path from "path";
import fs from "fs";
const JS2JAC = process.env.JS2JAC_DIR ||
  path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "js2jac");
const { convertEnvelope, PROTOCOL_VERSION } = await import(
  path.join(JS2JAC, "convert_bridge.mjs"));
const req = createRequire(path.join(JS2JAC, "vendor", "babel_parser", "package.json"));
const parser = req("@babel/parser");
function langOf(p){if(p.endsWith(".tsx"))return"tsx";if(p.endsWith(".ts"))return"ts";if(p.endsWith(".jsx"))return"jsx";return"js";}
function plug(l){const p=["estree"];if(l==="jsx"||l==="tsx")p.push("jsx");if(l==="ts"||l==="tsx")p.push("typescript");return p;}
const input = JSON.parse(fs.readFileSync(0, "utf8"));
let ast;
try { ast = parser.parse(input.js, { sourceType: "unambiguous", plugins: plug(langOf(input.path)), ranges: true, errorRecovery: false }); }
catch (e) { process.stdout.write(JSON.stringify({ ok:false, error:"parse:"+e.message })); process.exit(0); }
const res = convertEnvelope({ protocolVersion: PROTOCOL_VERSION, path: input.path, ast, failOpen: true, stmtFailOpen: true, emitHoles: true, source: input.js });
const jac = res.jac || "";
const holeCount = (jac.match(/JS2JAC-HOLE/g) || []).length;
const declHoleCount = (jac.match(/UNCONVERTED/g) || []).length ? (jac.split("# JS2JAC-HOLE").length - 1) : 0;
// codes feed the deterministic pre-REJECT (policy reject-codes drop the file
// without an LLM call); keep payload small — codes only, no messages.
const codes = [...new Set((res.diagnostics || []).map(d => d && d.code).filter(Boolean))];
process.stdout.write(JSON.stringify({ ok: res.ok === true, jac, holeCount, keptCount: res.keptCount||0, codes }));
