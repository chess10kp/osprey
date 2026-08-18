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

test("module Set and Map constructors lower iterable initializers", () => {
  const result = convert(`
    export const names = new Set(["a", "b"]);
    export const aliases = new Map([["a", "alpha"], ["b", "beta"]]);
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /glob:pub names = set\(\["a", "b"\]\);/);
  assert.match(result.jac, /glob:pub aliases = dict\(\[\["a", "alpha"\], \["b", "beta"\]\]\);/);
  assertJacChecks(result.jac);
});

test("bitwise operators preserve masks and shifts", () => {
  const result = convert(`
    export function masked(value: number, lock: number): number {
      return (value & ~lock) | (1 << 4);
    }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /float\(int\(value\) & int\(float\(~int\(lock\)\)\)\)/);
  assert.match(result.jac, /float\(int\(1\) << int\(4\)\)/);
  assertJacChecks(result.jac);
});

test("for-of flat destructuring binds through a synthetic item", () => {
  const result = convert(`
    export function joinPairs(pairs: [string, string][]): string {
      let output = "";
      for (const [key, value] of pairs) {
        output += key + value;
      }
      return output;
    }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /for _jx_item0 in pairs \{/);
  assert.match(result.jac, /key = _jx_item0\[0\];/);
  assert.match(result.jac, /value = _jx_item0\[1\];/);
  assertJacChecks(result.jac);
});

test("function-valued object globals preserve helper lambdas", () => {
  const result = convert(`
    export const Key = {
      escape: "escape",
      ctrl: <K extends string>(key: K): string => ` + "`ctrl+${key}`" + `,
    } as const;
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /glob:pub Key = \{/);
  assert.match(result.jac, /"ctrl": lambda \(key: any\)/);
});

test("identifier-based external constructors lower as interop calls", () => {
  const result = convert(`
    import { Parser } from "parser";
    const parser = new Parser("strict");
    export function current(): any { return parser; }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /glob parser: any = Parser\("strict"\);/);
  assertJacChecks(result.jac);
});

test("fail-open class members are emitted as explicit holes", () => {
  const result = convert(`
    export class Partial {
      segmenter = new Intl.Segmenter();
      *values(): Iterable<number> { yield 1; }
      ok(): string { return "ok"; }
    }
  `, "partial.ts", { failOpen: true, stmtFailOpen: true, emitHoles: true });
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /has segmenter: any = Intl\.Segmenter\(\);/);
  assert.match(result.jac, /JS2JAC-HOLE\[E7205\] Generator class methods are not supported/);
  assert.match(result.jac, /def ok\(\) -> str/);
});

test("string literals escape control characters in emitted Jac", () => {
  const result = convert(`
    export function newlineIndex(value: string): number {
      return value.indexOf("\\n");
    }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.ok(result.jac.includes(String.raw`"\n"`));
  assert.doesNotMatch(result.jac, /"\n"/);
  assertJacChecks(result.jac);
});

test("optional class fields and parameters lower as nullable defaults", () => {
  const result = convert(`
    export class Cache {
      private value?: string;
      set(value?: string): void { this.value = value; }
      clear(): void { this.value = undefined; }
    }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /has value: str \| None = None;/);
  assert.match(result.jac, /def set\(value: str \| None = None\) -> None/);
  assertJacChecks(result.jac);
});

test("class parameters infer types from literal defaults", () => {
  const result = convert(`
    export class Options {
      constructor(count = 1, label = "all", enabled = true) {}
    }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /count: float = 1/);
  assert.match(result.jac, /label: str = "all"/);
  assert.match(result.jac, /enabled: bool = True/);
  assertJacChecks(result.jac);
});

test("non-null assertions permit access through nullable class fields", () => {
  const result = convert(`
    export class Cache {
      private value?: { lines: string[] };
      lines(): string[] { return this.value!.lines; }
    }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /\(self\.value as any\)\.lines/);
  assertJacChecks(result.jac);
});

test("typed uninitialized local lets remain declarations", () => {
  const result = convert(`
    export function choose(flag: boolean): string {
      let result: string;
      if (flag) result = "yes";
      else result = "no";
      return result;
    }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /result: str;/);
  assertJacChecks(result.jac);
});

test("qualified constructors lower as explicit interop globals", () => {
  const result = convert(`
    export const segmenter = new Intl.Segmenter(undefined, { granularity: "word" });
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /glob Intl: any = None;/);
  assert.match(result.jac, /glob:pub segmenter: any = Intl\.Segmenter\(None, \{"granularity": "word"\}\);/);
  assert.equal(result.droppedCount, 0);
  assertJacChecks(result.jac);
});

test("re-exports erase type-only specifiers from runtime imports", () => {
  const result = convert(`
    export { type Shape, Runtime, type Config as RuntimeConfig } from "./values.ts";
    export type { OnlyType } from "./types.ts";
  `, "index.ts", { failOpen: true, emitHoles: true });
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /import from "\.\/values\.jac" \{ Runtime \}/);
  assert.doesNotMatch(result.jac, /Shape|Config|OnlyType|types\.jac/);
  assert.equal(result.droppedCount, 0);
});

test("callback parameters apply reserved-name renames at binding sites", () => {
  const result = convert(`
    export function compare(values: string[]): boolean {
      return values.every((match, code = 0) => match.length > code);
    }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /lambda \(match_j: any, code: any\)/);
  assert.match(result.jac, /len\(match_j\) > code/);
  assert.doesNotMatch(result.jac, /lambda \(match:/);
});

test("fixed global regex replacement lowers without Python regex interop", () => {
  const result = convert(`
    export function expandTabs(text: string): string {
      return text.replace(/\\t/g, "   ");
    }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.ok(result.jac.includes(String.raw`text.replace("\t", "   ")`));
  assert.doesNotMatch(result.jac, /import from re|\bsub\(/);
  assertJacChecks(result.jac);
});

test("JavaScript named regex groups lower to Python group syntax", () => {
  const result = convert(`
    export function hasWord(text: string): boolean {
      return /(?<word>[a-z]+)\\k<word>/.test(text);
    }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /\(\?P<word>\[a-z\]\+\)\(\?P=word\)/);
  assert.doesNotMatch(result.jac, /\(\?<word>|\\k<word>/);
  assertJacChecks(result.jac);
});

test("regex string splitting lowers through Python regex interop", () => {
  const result = convert(`
    export function words(query: string): string[] {
      return query.split(/[\\s/]+/).filter((word) => word.length > 0);
    }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /import from re \{ split \}/);
  assert.match(result.jac, /split\(r"\[\\s\/\]\+", query\)/);
  assertJacChecks(result.jac);
});

test("named match groups lower through Python groupdict", () => {
  const result = convert(`
    export function digits(value: string): string {
      const match = value.match(/(?<digits>[0-9]+)/);
      return match ? match.groups?.digits ?? "" : "";
    }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /match_j\.groupdict\(\)\.get\('digits'\)/);
  assert.doesNotMatch(result.jac, /\.groups\.digits/);
  assertJacChecks(result.jac);
});

test("numeric locals widen when fractional compound updates require it", () => {
  const result = convert(`
    export function score(text: string): number {
      const calculate = (value: string): number => {
        let score = 0;
        for (let i = 0; i < value.length; i++) score += i * 0.1;
        return score;
      };
      return calculate(text);
    }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /score: float = float\(0\);/);
  assert.match(result.jac, /score = float\(score \+ \(i \* 0\.1\)\);/);
  assert.match(result.jac, /i: int = 0;/);
  assertJacChecks(result.jac);
});

test("object-array comparator sort and map preserve dictionary access", () => {
  const result = convert(`
    export function rank(): string[] {
      const results: Array<{ item: string; totalScore: number }> = [
        { item: "late", totalScore: 2 },
        { item: "first", totalScore: 1 },
      ];
      results.sort((a, b) => a.totalScore - b.totalScore);
      let prefix = "";
      for (const result of results) prefix += result.item;
      return results.map((result) => result.item);
    }
  `, "fixture.ts", { failOpen: true, stmtFailOpen: true, emitHoles: true });
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /\.sort\(key=lambda \(_jx_sort: any\).*\["totalScore"\]/);
  assert.match(result.jac, /\(result\["item"\] as str\) for result in results/);
  assert.match(result.jac, /prefix \+= \(result\["item"\] as str\)/);
  assertJacChecks(result.jac);
});

test("record-returning helpers preserve field types at member access", () => {
  const result = convert(`
    function extract(value: string): { code: string; length: number } | undefined {
      return value ? { code: value, length: value.length } : undefined;
    }
    export function label(value: string): string {
      const found = extract(value);
      const wrapped = found ? { code: found.code } : { code: "" };
      return found ? found.code + str(found.length) : "";
    }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /\(found\["code"\] as str\)/);
  assert.match(result.jac, /\(found\["length"\] as float\)/);
  assert.doesNotMatch(result.jac, /len\(found\)/);
  assertJacChecks(result.jac);
});
