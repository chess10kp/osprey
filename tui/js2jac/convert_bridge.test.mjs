import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { convertEnvelope, PROTOCOL_VERSION } from "./convert_bridge.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const require = createRequire(path.join(here, "vendor", "babel_parser", "package.json"));
const parser = require("@babel/parser");

function convert(source, virtualPath = "fixture.ts", options = {}) {
  const ast = parser.parse(source, {
    sourceType: "module",
    plugins: ["estree", "typescript"],
    ranges: true,
  });
  return convertEnvelope({
    protocolVersion: PROTOCOL_VERSION,
    path: virtualPath,
    ast,
    source,
    ...options,
  });
}

function assertJacChecks(jac) {
  const tempDir = mkdtempSync(path.join(os.tmpdir(), "jackal-js2jac-"));
  const fixture = path.join(tempDir, "fixture.jac");
  try {
    writeFileSync(fixture, jac);
    const checked = spawnSync("jac", ["check", fixture], { encoding: "utf8" });
    assert.equal(
      checked.status,
      0,
      `jac check failed:\n${checked.stdout}${checked.stderr}\n--- emitted ---\n${jac}`,
    );
  } finally {
    rmSync(tempDir, { recursive: true, force: true });
  }
}

test("class lowering nests complete multiline methods inside the object", () => {
  const result = convert(`
    export class Counter {
      value: number = 0;
      increment(step: number): number {
        this.value += step;
        return this.value;
      }
    }
  `);

  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /obj:pub Counter \{/);
  assert.match(result.jac, /\n    def increment\(step: float\) -> float \{/);
  assert.match(result.jac, /\n        self\.value \+= step;/);
  assert.match(result.jac, /\n        return self\.value;/);
  assert.match(result.jac, /\n    \}\n\}/);
  assertJacChecks(result.jac);
});

test("repeat casts a TS number count to int", () => {
  const result = convert(`
    export function repeatText(value: string, count: number): string {
      return value.repeat(count);
    }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /value \* int\(count\)/);
  assert.doesNotMatch(result.jac, /count\.0/);
  assertJacChecks(result.jac);
});

test("discard-result splice deletes start through start plus count", () => {
  const result = convert(`
    export function remove(values: string[], start: number, count: number): void {
      values.splice(start, count);
    }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /del values\[start:\(start\) \+ \(count\)\];/);
  assertJacChecks(result.jac);
});

test("expression-valued splice fails closed", () => {
  const result = convert(`
    export function remove(values: string[]): string[] {
      return values.splice(0, 1);
    }
  `);
  assert.equal(result.ok, false);
  assert.ok(result.diagnostics.some((diag) => diag.code === "E7215"));
});

test("Math max and min normalize every argument to float", () => {
  const result = convert(`
    export function clamp(value: number): number {
      const floor = 2;
      return Math.max(floor, Math.min(value, 3.5));
    }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /max\(float\(floor\), float\(min\(float\(value\), float\(3\.5\)\)\)\)/);
  assertJacChecks(result.jac);
});

test("zero-argument Math max fails closed", () => {
  const result = convert(`
    export function largest(): number { return Math.max(); }
  `);
  assert.equal(result.ok, false);
  assert.ok(result.diagnostics.some((diag) => diag.code === "E7215"));
});

test("synthetic this fields default to None instead of becoming required", () => {
  const result = convert(`
    export class Dynamic {
      name: string;
      constructor(name: string) { this.name = name; }
      setValue(value: string): void { this.dynamic = value; }
    }
    export function make(): Dynamic { return new Dynamic("fixture"); }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /has dynamic: any = None;/);
  assert.ok(result.jac.indexOf("has name: str;") < result.jac.indexOf("has dynamic: any = None;"));
  assertJacChecks(result.jac);
});

test("derived-class calls do not synthesize inherited methods as fields", () => {
  const result = convert(`
    class Base { emit(): void {} }
    export class Child extends Base { go(): void { this.emit(); } }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.doesNotMatch(result.jac, /has emit:/);
});

test("indexOf preserves minus-one-on-miss for stable operands", () => {
  const result = convert(`
    export function locate(value: string, needle: string): number {
      return value.indexOf(needle);
    }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /\(-1 if needle not in value else value\.index\(needle\)\)/);
  assertJacChecks(result.jac);
});

test("indexOf with a side-effecting operand fails closed", () => {
  const result = convert(`
    declare function nextNeedle(): string;
    export function locate(value: string): number {
      return value.indexOf(nextNeedle());
    }
  `);
  assert.equal(result.ok, false);
  assert.ok(result.diagnostics.some((diag) => diag.code === "E7215"));
});

test("nullish coalescing lowers stable operands without changing evaluation count", () => {
  const result = convert(`
    export function fallback(value: string | undefined): string {
      return value ?? "default";
    }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /value if value is not None else "default"/);
  assertJacChecks(result.jac);
});

test("nullish coalescing with a side-effecting left operand fails closed", () => {
  const result = convert(`
    declare function nextValue(): string | undefined;
    export function fallback(): string {
      return nextValue() ?? "default";
    }
  `);
  assert.equal(result.ok, false);
  assert.ok(result.diagnostics.some((diag) => diag.code === "E7215"));
});

test("type-only modules erase successfully instead of hard rejecting", () => {
  const result = convert(`
    import type { Base } from "./base.ts";
    export interface Surface extends Base {
      read(): string;
      write?(value: string): void;
    }
    export type Name = string;
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.equal(result.droppedCount, 0);
  assert.equal(result.jac, "\n");
  assert.ok(result.mappings.some((mapping) => mapping.rule_id === "ts.module.type-erasure.v1"));
});

test("pure module factory calls lower to explicit interop globals", () => {
  const result = convert(`
    import { getSegmenter } from "./segmenter.ts";
    const segmenter = getSegmenter("word");
    export function current(): any { return segmenter; }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /glob segmenter = getSegmenter\("word"\);/);
  assert.equal(result.droppedCount, 0);
  assertJacChecks(result.jac);
});

test("module factory calls with spread arguments remain unsupported", () => {
  const result = convert(`
    declare function build(...values: string[]): unknown;
    const values = ["a", "b"];
    export const built = build(...values);
  `);
  assert.equal(result.ok, false);
  assert.ok(result.diagnostics.some((diag) => diag.code === "E7205"));
});

test("optional member plus nullish fallback preserves short-circuiting", () => {
  const result = convert(`
    export function label(value: any): string {
      return value?.label ?? "default";
    }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /value\.label if value is not None else None/);
  assert.match(result.jac, /is not None else "default"/);
});

test("optional calls lower only for stable call targets", () => {
  const stable = convert(`
    export function notify(callback: any, value: string): any {
      return callback?.(value);
    }
  `);
  assert.equal(stable.ok, true, JSON.stringify(stable.diagnostics));
  assert.match(stable.jac, /callback\(value\) if callback is not None else None/);

  const effectful = convert(`
    declare function nextCallback(): any;
    export function notify(value: string): any {
      return nextCallback()?.(value);
    }
  `);
  assert.equal(effectful.ok, false);
  assert.ok(effectful.diagnostics.some((diag) => diag.code === "E7215"));
});

test("import meta url lowers to the server file anchor", () => {
  const result = convert(`
    import { createRequire } from "node:module";
    const require = createRequire(import.meta.url);
    export function current(): any { return require; }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /glob require = createRequire\(__file__\);/);
  assertJacChecks(result.jac);
});

test("uninitialized typed let becomes a nullable module global", () => {
  const result = convert(`
    type Helper = { ready: boolean };
    let helper: Helper | null | undefined;
    export function current(): any { return helper; }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /glob helper: any \| None = None;/);
  assertJacChecks(result.jac);
});

test("native module patterns emit a reviewable fail-open floor", () => {
  const result = convert(`
    import { createRequire } from "node:module";
    const cjsRequire = createRequire(import.meta.url);
    type Helper = { run: (value: string) => boolean };
    let helper: Helper | null | undefined;
    export function run(value: string): boolean {
      if (!helper) return false;
      try { return helper.run(value); } catch { return false; }
    }
  `, "native.ts", { failOpen: true, stmtFailOpen: true, emitHoles: true });
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.equal(result.droppedCount, 1);
  assert.match(result.jac, /glob cjsRequire = createRequire\(__file__\);/);
  assert.match(result.jac, /glob helper: any \| None = None;/);
  assert.match(result.jac, /JS2JAC-HOLE\[E7200\] Declaration produced no output/);
  assert.match(result.jac, /try \{ return helper\.run\(value\); \} catch/);
});
