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

test("class getters lower to zero-argument abilities with explicit self calls", () => {
  const result = convert(`
    export class Queue {
      items: string[] = [];
      get length(): number { return this.items.length; }
      empty(): boolean { return this.length === 0; }
    }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /def length\(\) -> float \{/);
  assert.match(result.jac, /return len\(self\.items\);/);
  assert.match(result.jac, /return \(self\.length\(\) == 0\);/);
  assertJacChecks(result.jac);
});

test("async class methods emit Jac async abilities and preserve await", () => {
  const result = convert(`
    export class Loader {
      async load(value: any): Promise<string> { return await value; }
    }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /async def load\(value: any\) -> any \{/);
  assert.match(result.jac, /return await value;/);
  assertJacChecks(result.jac);
});

test("await preserves class receiver context in nested call arguments", () => {
  const result = convert(`
    export class Loader {
      client: any;
      async load(value: any): Promise<string> {
        return await fetchValue(this.client, value);
      }
    }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /return await fetchValue\(self\.client, value\);/);
  assertJacChecks(result.jac);
});

test("class method object parameters lower through a synthetic typed boundary", () => {
  const result = convert(`
    export class FocusManager {
      current: any = null;
      setFocus({ component, restore }: { component: any; restore: string }): void {
        this.current = component;
        if (restore === "clear") this.current = null;
      }
    }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /def setFocus\(_jx_p0: any\) -> None \{/);
  assert.match(result.jac, /component = _jx_p0\.component;/);
  assert.match(result.jac, /restore = _jx_p0\.restore;/);
  assert.match(result.jac, /self\.current = component;/);
  assertJacChecks(result.jac);
});

test("nested class method parameter patterns remain fail closed", () => {
  const result = convert(`
    export class FocusManager {
      setFocus({ nested: { component } }: { nested: { component: any } }): void {}
    }
  `);
  assert.equal(result.ok, false);
  assert.ok(result.diagnostics.some((diag) => diag.code === "E7232"));
});

test("class setters remain fail-closed", () => {
  const result = convert(`
    export class Counter {
      set value(next: number) {}
    }
  `);
  assert.equal(result.ok, false);
  assert.ok(result.diagnostics.some((diag) =>
    diag.code === "E7205" && diag.message.includes("setters")));
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

test("C-style index loops lower to checked Jac while loops", () => {
  const result = convert(`
    export function sum(values: number[]): number {
      let total: number = 0;
      for (let i = 0; i < values.length; ++i) {
        total += values[i];
      }
      for (let i = values.length - 1; i >= 0; i -= 1) {
        total += values[i];
      }
      return total;
    }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /i: int = 0;\n    while \(i < len\(values\)\)/);
  assert.match(result.jac, /i \+= 1;/);
  assert.match(result.jac, /i -= 1;/);
  assertJacChecks(result.jac);
});

test("binary in expressions preserve dictionary-key membership", () => {
  const result = convert(`
    export function hasName(value: string): boolean {
      return value in { name: true };
    }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /return \(value in \{"name": True\}\);/);
  assertJacChecks(result.jac);
});

test("switch groups consecutive empty case labels into one branch", () => {
  const result = convert(`
    export function anchor(value: string): number {
      switch (value) {
        case "left":
        case "center":
        case "right":
          return 1;
        case "bottom":
          return 2;
        default:
          return 0;
      }
    }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /\(_sw == "left"\) or \(_sw == "center"\) or \(_sw == "right"\)/);
  assertJacChecks(result.jac);
});

test("switch still rejects genuine statement fallthrough", () => {
  const result = convert(`
    export function unsafe(value: string): number {
      switch (value) {
        case "left": value = "right";
        case "right": return 1;
      }
    }
  `);
  assert.equal(result.ok, false);
  assert.ok(result.diagnostics.some((diag) => diag.code === "E7230"));
});

test("simple instanceof guards lower to Jac isinstance", () => {
  const result = convert(`
    class Container { marker: boolean = true; }
    export class Tree {
      contains(value: any): boolean {
        if (!(value instanceof Container)) return false;
        return true;
      }
    }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /if not isinstance\(value, Container\)/);
  assertJacChecks(result.jac);
});

test("instanceof with an unstable constructor remains unsupported", () => {
  const result = convert(`export function matches(value: any): boolean {
    return value instanceof getConstructor();
  }`);
  assert.equal(result.ok, false);
  assert.ok(result.diagnostics.some((diag) => diag.code === "E7215"));
});

test("statement void calls and stable prefix increments preserve effects", () => {
  const result = convert(`
    export class Scheduler {
      counter: number = 0;
      launch(): any { return null; }
      run(): any {
        const entry = { order: ++this.counter };
        void this.launch();
        return entry;
      }
    }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /"order": \(lambda \(\) -> any \{ self\.counter \+= 1; return self\.counter; \}\)\(\)/);
  assert.match(result.jac, /self\.launch\(\);/);
  assertJacChecks(result.jac);
});

test("stable task-slot async IIFEs preserve queued execution", () => {
  const result = convert(`
    export class Scheduler {
      task: any;
      counter: number = 0;
      async run(): Promise<void> {
        const previousTask = this.task;
        this.task = (async () => {
          await previousTask;
          const requestId = ++this.counter;
          await this.perform(requestId);
        })();
        await this.task;
      }
      async perform(requestId: number): Promise<void> {}
    }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /import asyncio;/);
  assert.match(result.jac, /async def _jx_async_task\d+\(\)/);
  assert.match(result.jac, /self\.task = asyncio\.create_task\(_jx_async_task\d+\(\)\);/);
  assert.match(result.jac, /await previousTask;/);
  assertJacChecks(result.jac);
});

test("async IIFEs outside stable task-slot assignment remain unsupported", () => {
  const result = convert(`export async function run(): Promise<void> {
    consume((async () => { await perform(); })());
  }`);
  assert.equal(result.ok, false);
  assert.ok(result.diagnostics.some((diag) => diag.code === "E7215"));
});

test("unstable prefix increment targets remain unsupported", () => {
  const result = convert(`export function next(): number {
    return ++getCounter().value;
  }`);
  assert.equal(result.ok, false);
  assert.ok(result.diagnostics.some((diag) => diag.code === "E7215"));
});

test("TypeScript type-predicate returns lower to bool", () => {
  const result = convert(`
    export function isText(value: unknown): value is string {
      return typeof value === "string";
    }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /def:pub isText\(value: any\) -> bool/);
  assert.match(result.jac, /return isinstance\(value, str\);/);
  assertJacChecks(result.jac);
});

test("stable typeof object and function guards lower without widening null or primitives", () => {
  const result = convert(`
    export function hasHandler(value: unknown): boolean {
      if (typeof value !== "object" || value === null) return false;
      const candidate = (value as { run?: unknown }).run;
      return typeof candidate === "function";
    }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /not isinstance\(value, \(str, int, float, bool\)\)/);
  assert.match(result.jac, /not callable\(value\)/);
  assert.match(result.jac, /return bool\(callable\(candidate\)\);/);
  assertJacChecks(result.jac);
});

test("effectful typeof object and function operands remain unsupported", () => {
  for (const source of [
    `export function isObject(): boolean { return typeof getValue() === "object"; }`,
    `export function isFunction(): boolean { return typeof getValue() === "function"; }`,
  ]) {
    const result = convert(source);
    assert.equal(result.ok, false);
    assert.ok(result.diagnostics.some((diag) => diag.code === "E7215"));
  }
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

test("three-argument splice replaces a slice in statement position", () => {
  const result = convert(`
    export function insert(values: string[], start: number, value: string): void {
      values.splice(start, 0, value);
    }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /values\[start:\(start\) \+ \(0\)\] = \[value\];/);
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

test("Math max lowers a spread iterable with numeric normalization", () => {
  const result = convert(`
    export function largest(values: number[]): number {
      return Math.max(...values);
    }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /max\(\*\[float\(_jx_math\) for _jx_math in values\]\)/);
  assertJacChecks(result.jac);
});

test("discarded push of one spread iterable lowers to list extension", () => {
  const result = convert(`
    export function appendAll(values: string[], added: string[]): void {
      values.push(...added);
    }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /values\.extend\(added\);/);
  assertJacChecks(result.jac);
});

test("discarded unshift lowers to a front insert", () => {
  const result = convert(`
    export function prepend(values: string[], item: string): void {
      values.unshift(item);
    }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /values\.insert\(0, item\);/);
  assertJacChecks(result.jac);
});

test("shift lowers to pop of the first element", () => {
  const result = convert(`
    export function takeFirst(values: string[]): string {
      return values.shift();
    }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /values\.pop\(0\)/);
  assertJacChecks(result.jac);
});

test("length-reset assignment lowers to clear", () => {
  const result = convert(`
    export function reset(values: string[]): void {
      values.length = 0;
    }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /values\.clear\(\);/);
  assert.doesNotMatch(result.jac, /len\(values\) = 0/);
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
  assert.match(result.jac, /lambda \(_jx_null0: any\).*_jx_null0 if _jx_null0 is not None else "default"/s);
  assertJacChecks(result.jac);
});

test("nullish coalescing evaluates a side-effecting left operand once", () => {
  const result = convert(`
    declare function nextValue(): string | undefined;
    export function fallback(): string {
      return nextValue() ?? "default";
    }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.equal((result.jac.match(/nextValue\(\)/g) ?? []).length, 1);
  assert.match(result.jac, /def nextValue -> str \| None;/);
  assert.match(result.jac, /lambda \(_jx_null0: any\)/);
  assertJacChecks(result.jac);
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
  assert.match(result.jac, /lambda \(_jx_opt0: any\).*_jx_opt0\.label if _jx_opt0 is not None else None/s);
  assert.match(result.jac, /lambda \(_jx_null1: any\).*else "default"/s);
  assertJacChecks(result.jac);
});

test("optional calls evaluate stable and effectful call targets once", () => {
  const stable = convert(`
    export function notify(callback: any, value: string): any {
      return callback?.(value);
    }
  `);
  assert.equal(stable.ok, true, JSON.stringify(stable.diagnostics));
  assert.match(stable.jac, /_jx_opt0\(value\) if _jx_opt0 is not None else None/);

  const effectful = convert(`
    declare function nextCallback(): any;
    export function notify(value: string): any {
      return nextCallback()?.(value);
    }
  `);
  assert.equal(effectful.ok, true, JSON.stringify(effectful.diagnostics));
  assert.equal((effectful.jac.match(/nextCallback\(\)/g) ?? []).length, 1);
  assert.match(effectful.jac, /_jx_opt0\(value\) if _jx_opt0 is not None else None/);
  assertJacChecks(effectful.jac);
});

test("whole optional-chain suffixes stay guarded with hygienic temps", () => {
  const result = convert(`
    declare function next(): any;
    export function read(): any {
      const _jx_opt0 = "source";
      return next()?.child.label;
    }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.equal((result.jac.match(/next\(\)/g) ?? []).length, 1);
  assert.match(result.jac, /lambda \(_jx_opt1: any\).*_jx_opt1\.child\.label if _jx_opt1 is not None else None/s);
  assertJacChecks(result.jac);
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
  assert.equal(result.droppedCount, 0);
  assert.match(result.jac, /glob cjsRequire = createRequire\(__file__\);/);
  assert.match(result.jac, /glob helper: any \| None = None;/);
  assert.match(result.jac, /try \{/);
  assert.match(result.jac, /except Exception \{/);
  assert.doesNotMatch(result.jac, /JS2JAC-HOLE/);
});

test("try catch finally lowers with renamed catch bindings", () => {
  const result = convert(`
    export function recover(value: string): string {
      try {
        return int(value).toString();
      } catch (match) {
        return String(match);
      } finally {
        value = value.trim();
      }
    }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /try \{/);
  assert.match(result.jac, /except Exception as match_j \{/);
  assert.match(result.jac, /finally \{/);
  assertJacChecks(result.jac);
});

test("class field try IIFEs parenthesize emitted lambdas", () => {
  const result = convert(`
    export class Probe {
      value = (() => {
        try { return 1; } catch { return 0; }
      })();
    }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /has value: any = \(lambda \(\) -> any \{ try \{/);
  assert.match(result.jac, /except Exception \{/);
  assert.match(result.jac, /\}\)\(\);/);
  assertJacChecks(result.jac);
});

test("catch destructuring remains fail closed", () => {
  const result = convert(`
    export function recover(): string {
      try { return "ok"; } catch ({ message }) { return message; }
    }
  `);
  assert.equal(result.ok, false);
  assert.ok(result.diagnostics.some((diag) => diag.code === "E7230"));
});

test("throw new Error lowers to a Jac Exception raise", () => {
  const result = convert(`
    export function fail(message: string): void {
      throw new Error(message);
    }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /raise Exception\(message\);/);
  assertJacChecks(result.jac);
});

test("throwing arbitrary JavaScript values remains fail closed", () => {
  const result = convert(`
    export function fail(): void { throw "failure"; }
  `);
  assert.equal(result.ok, false);
  assert.ok(result.diagnostics.some((diag) =>
    diag.code === "E7230" && diag.message.includes("throw new Error")));
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

test("known Map bindings lower their JS-only mutation and iterator API", () => {
  const result = convert(`
    const cache = new Map<string, number>();
    export function remember(key: string, value: number): number {
      if (cache.size >= 2) {
        const first = cache.keys().next().value;
        if (first !== undefined) cache.delete(first);
      }
      cache.set(key, value);
      return cache.get(key)!;
    }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /len\(cache\) >= 2/);
  assert.match(result.jac, /first = next\(iter\(cache\.keys\(\)\), None\)/);
  assert.match(result.jac, /cache\.pop\(first, None\);/);
  assert.match(result.jac, /cache\[key\] = value;/);
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

test("statement bitwise compound assignments coerce simple bindings", () => {
  const result = convert(`
    export function mask(enabled: boolean): number {
      let value: number = 0;
      if (enabled) value |= 4;
      value ^= 1;
      return value;
    }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /value = float\(int\(value\) \| int\(4\)\);/);
  assert.match(result.jac, /value = float\(int\(value\) \^ int\(1\)\);/);
  assertJacChecks(result.jac);
});

test("bitwise compound assignment to a member remains fail closed", () => {
  const result = convert(`
    export function mask(box: any): void { box.value |= 4; }
  `);
  assert.equal(result.ok, false);
  assert.ok(result.diagnostics.some((diag) => diag.code === "E7215"));
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
  assert.match(result.jac, /import from \.values \{ Runtime \}/);
  assert.doesNotMatch(result.jac, /Shape|Config|OnlyType|types\.jac/);
  assert.equal(result.droppedCount, 0);
});

test("relative imports lower to dotted module syntax, not quoted string paths", () => {
  // jac 0.36.0 drops cross-file return types to Unknown for quoted string-path
  // relative imports (`import from "./a.jac" { ... }`); the dotted form
  // (`import from .a { ... }`) type-checks clean. See jac#8371.
  const result = convert(`
    import { helper } from "./utils";
    import { sub } from "./components/box";
    import { up } from "../shared";
    export function run(): void {
      helper(); sub(); up();
    }
  `, "index.ts");
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /import from \.utils \{ helper \}/);
  assert.match(result.jac, /import from \.components\.box \{ sub \}/);
  assert.match(result.jac, /import from \.\.shared \{ up \}/);
  assert.doesNotMatch(result.jac, /import from "\./);
});

test("relative imports to kebab-case source files snake_case the module path and still lower to dotted syntax", () => {
  // Dotted syntax has no escape for '-' in a segment, and source basenames
  // are commonly kebab-case (`kill-ring.ts`). Rather than falling back to the
  // buggy quoted form for these, jacModulePath() snake_cases every path
  // segment (kill-ring -> kill_ring) so the rewritten specifier is always a
  // valid Jac identifier and qualifies for the dotted import form. The
  // regeneration driver (tui/scripts/js2jac_pi_tui.sh) names the on-disk
  // `.jac` file with the identical transform so the import resolves.
  const result = convert(`
    import { KillRing } from "./kill-ring";
    import { NativeMod } from "../native-modifiers";
    export function run(): void {
      new KillRing(); new NativeMod();
    }
  `, "index.ts");
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /import from \.kill_ring \{ KillRing \}/);
  assert.match(result.jac, /import from \.\.native_modifiers \{ NativeMod \}/);
  assert.doesNotMatch(result.jac, /import from "\./);
  assert.doesNotMatch(result.jac, /kill-ring|native-modifiers/);
});

test("re-exports from kebab-case source files also snake_case the module path", () => {
  // lowerReExport() routes through jacModulePath() too; a barrel re-export
  // of a kebab-case sibling must get the same snake_case + dotted treatment
  // as a plain import.
  const result = convert(`
    export { KillRing } from "./kill-ring.ts";
  `, "index.ts", { failOpen: true, emitHoles: true });
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /import from \.kill_ring \{ KillRing \}/);
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
  assert.match(result.jac, /if match_j else None/);
  assert.doesNotMatch(result.jac, /match_j\.groups/);
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

test("typed numeric flow, local classes, and direct record fields remain precise", () => {
  const result = convert(`
    class Tracker {
      active(): string { return "on"; }
    }
    function measure(): number { return 1; }
    export function render(tracker: Tracker): string {
      let width = 0;
      const measured = measure();
      width += measured;
      let offset = 0;
      const found = inspect("x");
      offset += found.length;
      let output = "";
      output += tracker.active();
      return inspect(output).text + str(width + offset);
    }
    function inspect(value: string): { text: string; length: number } {
      return { text: value, length: value.length };
    }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /tracker: Tracker/);
  assert.match(result.jac, /width: float = float\(0\)/);
  assert.match(result.jac, /measured: float = float\(measure\(\)\)/);
  assert.match(result.jac, /offset \+= int\(\(found\["length"\] as float\)\)/);
  assert.match(result.jac, /output: str = ""/);
  assert.match(result.jac, /\(inspect\(output\)\["text"\] as str\)/);
  assertJacChecks(result.jac);
});

test("segmenter destructuring and string-method locals keep string types", () => {
  const result = convert(`
    const segmenter = new Intl.Segmenter(undefined, { granularity: "grapheme" });
    export function joinSegments(text: string): string {
      let result = "";
      for (const { segment } of segmenter.segment(text)) result += segment;
      let trimmed = result.trimEnd();
      trimmed += "!";
      return trimmed;
    }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  assert.match(result.jac, /segment: str = \(_jx_item0\.segment as str\)/);
  assert.match(result.jac, /trimmed: str = result\.rstrip\(\)/);
  assertJacChecks(result.jac);
});

test("inline object-literal params lower member access to dict subscript", () => {
  const result = convert(`
    export function push(text: string, opts: { accumulate?: boolean; prepend?: boolean }): string {
      if (opts.accumulate) return text + "!";
      if (opts?.prepend) return "!" + text;
      return text;
    }
    export class Ring {
      add(entry: string, flags: { force: boolean }): boolean {
        return flags.force;
      }
    }
  `);
  assert.equal(result.ok, true, JSON.stringify(result.diagnostics));
  // Free function: dict subscript, not dict-DOT access.
  assert.match(result.jac, /opts\["accumulate"\]/);
  // Optional chaining (`opts?.prepend`) still lowers to bracket access, wrapped
  // in a None-guard over a synthetic receiver.
  assert.match(result.jac, /\["prepend"\] if .* is not None/);
  assert.doesNotMatch(result.jac, /opts\.accumulate/);
  assert.doesNotMatch(result.jac, /\.prepend/);
  // Method param typed with an inline object literal.
  assert.match(result.jac, /flags\["force"\]/);
  assert.doesNotMatch(result.jac, /flags\.force/);
  assertJacChecks(result.jac);
});
