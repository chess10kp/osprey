#!/usr/bin/env bun
/**
 * V1 js2jac normalize+emit bridge.
 * Reads parser envelope JSON on stdin, writes { ok, jac, diagnostics, mappings, summary }.
 *
 * V1.2 slice: adds React hooks (useState -> component-local `has` with direct
 * setter assignment; mount-only useEffect -> `can with entry`) and multi-statement
 * component bodies.
 * V1.3 slice: useEffect dependency arrays (-> `can with [state] entry`, where each
 * dep must resolve to a useState field declared earlier) and useRef (->
 * `has r: Ref[T] = Ref(...)`; `useRef(null)` -> the empty `Ref = Ref()` form).
 * V1.4 slice: JSX list comprehensions — a single-parameter `.map(x => <el>)` in a
 * JSX child lowers to `{[<el> for x in xs]}` (the W3042 idiom). Every `.map()`
 * that is not an approved GUARDED mapping (multi-param/index callbacks, block or
 * non-JSX bodies, non-arrow callbacks) fails closed with an E72xx diagnostic so
 * the dataset never records an unsafe rewrite.
 * V1.5 slice: TS array/tuple prop types — `string[]` -> `list[str]`, `[a, b]` ->
 * `tuple[a, b]`, nesting recursively (`string[][]` -> `list[list[str]]`). Empty
 * tuples and rest elements (`...T[]`) fail closed with E7201; their TS/Jac
 * semantics do not line up cleanly.
 * V1.6 slice: React hook import binding — `import { useState as s } from 'react'`
 * resolves `s(0)` to the same lowering as `useState(0)`. Only named imports from
 * `'react'` participate; namespace/default imports and member callees (`React.useState`)
 * remain out of scope.
 * V1.7 slice: TS union/optional prop types — `string | number` -> `str | float`,
 * `name?: string` -> `name: str | None`, `T | null` / `T | undefined` -> `T | None`.
 * Composes with V1.5 array/tuple forms inside unions and object literals.
 * V1.8 slice: useEffect dependency arrays accept prop field accesses — `[props.id]`
 * lowers to `can with [props.id] entry` when `props` is the component parameter;
 * useState field names and `props` / `props.field` may be mixed. Ref fields, deep
 * member access, calls, and literals remain rejected (E7212).
 * V1.9 slice: React default/namespace hook imports — `import React from 'react'`
 * and `import * as R from 'react'` let `React.useState(0)` / `R.useEffect(...)` lower
 * like direct hook spelling. Type-only imports and non-react sources are ignored.
 * V1.10 slice: TS generic array prop types — `Array<string>` / `ReadonlyArray<T>` ->
 * `list[T]`, nesting and unions compose with V1.5/V1.7. Other type references
 * (`Promise<T>`, `Record<K,V>`, custom aliases) remain rejected (E7201).
 * V1.11 slice: props destructuring — `function app({ id, label }: { id: string })`
 * lowers to named Jac parameters (`id: str, label: str`). Optional types and
 * pattern defaults compose with V1.7. `useEffect` deps may name destructured
 * props directly (`[id]`). Rest props, rename, nested destructuring, and type
 * aliases remain rejected (E7204/E7201).
 * V1.12 slice: children prop types — `React.ReactNode` / `ReactNode` /
 * `JSX.Element` lower to `any`; optional destructured `children` gains `= None`
 * per Jac component convention. `PropsWithChildren` and other generic children
 * wrappers remain rejected (E7201).
 * V1.13 slice: React.FC wrapper stripping — `export const C: React.FC<T> = ...`
 * unwraps the FC annotation and uses `T` as the props type when arrow parameters
 * lack an inline annotation. `FC` / `FunctionComponent` spellings compose with
 * V1.11/V1.12. `ComponentType`, type-alias generics, and FC without both a
 * type argument and inline props annotation fail closed (E7201).
 * V1.14 slice: forwardRef wrapper stripping — `export const C = forwardRef<T, P>(...)`
 * unwraps the HOC and emits a trailing `ref: Ref[T]` parameter. The callback must
 * be an arrow with exactly `(props, ref)` parameters where `ref` is not aliased.
 * Ref element type `T` comes from the first generic argument or a `ForwardedRef<T>`
 * annotation on the ref parameter. Props type `P` composes with V1.11/V1.12.
 * Non-trailing ref parameters and missing ref element types fail closed (E7218);
 * `memo(forwardRef(...))` is supported via the V1.15 memo slice below.
 *
 * V1.15 slice: React.memo wrapper stripping — `export const C = memo(callback)`
 * or `React.memo(callback)` strips the HOC and lowers the inner arrow as a plain
 * component. memo composes with forwardRef (`memo(forwardRef(...))`) and FC. A
 * single generic supplies the props type as a lowest-precedence fallback (inline
 * annotation and forwardRef/FC generics win). A custom props comparator (the
 * second argument) fails closed (E7219).
 *
 * V1.16 slice: props-bag named-param decomposition — a single `props` identifier
 * param with an inline object type (`props: { id: string }`) decomposes into
 * named Jac parameters, and the body's `props.id` accesses rewrite to bare `id`.
 * This is the idiomatic Jac form (props are plain function parameters) and the
 * only props-bag shape that type-checks. Non-decomposable uses (spreading
 * `props`, passing it whole, computed/unknown-field access) fail closed (E7220).
 *
 * V1.17 slice: external props type aliases — `props: AppProps` and destructured
 * `({ id }: Props)` where `Props` is not an inline object literal fail closed
 * (E7221). Inline object types and V1.16 decomposition remain the supported path.
 *
 * V1.18 slice: function/render-prop children — `children: (x) => ...` types lower
 * to `any`; JSX `{children(item)}` call expressions preserve call semantics.
 *
 * V1.19 slice: useMemo/useCallback interop — hooks with no native Jac lowering are
 * preserved as React interop calls (with `import from react { ... }` when needed).
 * Unsupported hooks beyond the supported/interop set still fail closed (E7208).
 *
 * V2.8 slice: Jac-native list/dict idioms in helper and component bodies —
 * `.push(arg)` -> `.append(arg)`, `arr.join(sep)` -> `sep.join(arr)`,
 * expression-position `.map(x => expr)` -> `[expr for x in arr]`, dict literal
 * and tracked dict bindings use bracket access (`d["key"]`), and common JS string
 * methods (`toUpperCase`, `trim`, ...) lower to Jac spellings (`upper`, `strip`).
 *
 * V2.9 slice: external props type alias resolution — module-level `type` /
 * `interface` declarations are collected and inlined when a component props
 * annotation references them (`props: AppProps`, `({ id }: Props)`,
 * `React.FC<ButtonProps>`, `memo<AppProps>`). Unresolved or unsupported
 * references (unknown name, `PropsWithChildren<T>`, generic args on a bare ref)
 * still fail closed with `E7221`.
 *
 * V2.11 slice: ClassDeclaration -> Jac `obj` / `obj(Base)` with `has` fields,
 * `def`/`override def` methods, `def __init__` constructors, `self`/`super`
 * lowering, and static-readonly literal hoists to module `glob`. Imported bases
 * emit anyway (per-file `jac check` may warn on Unknown base types). Simple
 * `for (let i = 0; i < n; i++)` loops and `i++` updates lower for class bodies.
 */
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import ruleCatalog from "./mapping_rules.json";
import {
  boundSiblingNames,
  collectBoundNames,
  collectPatternNames,
  collectReferencedNames,
  containsReturn,
  declaredNames,
} from "./convert/ast_analysis.mjs";

const PROTOCOL_VERSION = 1;
const __dirname = dirname(fileURLToPath(import.meta.url));
const RULE_BY_ID = new Map((ruleCatalog.rules ?? []).map((r) => [r.rule_id, r]));
const RULE_SET_VERSION = ruleCatalog.rule_set_version ?? "js2jac-client-v1";
const SUPPORTED_HOOKS = new Set(["useState", "useRef", "useEffect"]);
const INTEROP_HOOKS = new Set(["useMemo", "useCallback"]);
// Local names of consumed React default/namespace imports (`import React from
// 'react'` / `import * as R from 'react'`). React namespaces are lowered away,
// so a *computed* member access on one (`React['useState']`) cannot resolve and
// would emit a dangling reference. Reset per file at the top of convertEnvelope
// and read in emitMemberAccess to fail such access closed (E7214). Module-scoped
// because the emit layer runs below where hookBindings is threaded.
let REACT_NAMESPACE_LOCALS = new Set();
// Hole-emission mode (LLM-cleanup pipeline). Per-file reset in convertEnvelope.
// When `emitHoles` is on, a dropped statement/declaration leaves a
// `# JS2JAC-HOLE[code]` comment carrying the ORIGINAL JS source (sliced from
// `source` via the node's `.range`) so a downstream LLM pass has full local
// context. Default off -> sound conversion is byte-identical.
let HOLE_CTX = { emitHoles: false, source: null };

/** Slice the original JS text a node spans, or null if unavailable. */
function holeSourceOf(node) {
  const src = HOLE_CTX.source;
  const r = node?.range;
  if (typeof src !== "string" || !Array.isArray(r) || r.length < 2) return null;
  return src.slice(r[0], r[1]);
}

/** Build the `# JS2JAC-HOLE[...]` comment lines for a dropped node. Multi-line
 * JS is preserved with a `# | ` gutter so the LLM sees the exact original. */
function holeCommentLines(node, code, msg) {
  const head = `# JS2JAC-HOLE[${code}]${msg ? ` ${msg}` : ""}:`;
  const js = holeSourceOf(node);
  if (js == null) return [`${head} <source unavailable>`];
  return [head, ...js.split("\n").map((l) => `# | ${l}`)];
}
const CHILDREN_TS_TYPES = new Set([
  "ReactNode",
  "ReactChild",
  "ReactChildren",
  "ReactElement",
  "React.ReactNode",
  "React.ReactChild",
  "React.ReactChildren",
  "React.ReactElement",
  "JSX.Element",
]);
const FC_TYPE_NAMES = new Set([
  "FC",
  "React.FC",
  "FunctionComponent",
  "React.FunctionComponent",
]);
const FORWARDED_REF_TYPE_NAMES = new Set([
  "ForwardedRef",
  "React.ForwardedRef",
  "LegacyRef",
  "React.LegacyRef",
  "Ref",
  "React.Ref",
  "MutableRefObject",
  "React.MutableRefObject",
]);
const REF_ELEMENT_TYPE_NAMES = new Set([
  "Element",
  "HTMLElement",
  "SVGElement",
]);
/** V2.8: JS string methods that lower to Jac spellings on `str`. */
const JS_STRING_METHODS = {
  toUpperCase: "upper",
  toLowerCase: "lower",
  trim: "strip",
  trimStart: "lstrip",
  trimEnd: "rstrip",
  startsWith: "startswith",
  endsWith: "endswith",
};

// Number/Date formatting methods that return a locale/precision-formatted STRING
// with no sound Jac equivalent. Emitting them raw (`x.toFixed(2)`) type-checks as
// an unknown attribute (E1030) and sinks the whole file; we diagnose so fail-open
// drops just the offending expression/statement and keeps the rest.
const JS_UNSUPPORTED_NUMBER_METHODS = new Set([
  "toFixed", "toPrecision", "toExponential", "toLocaleString", "toLocaleDateString", "toLocaleTimeString",
]);

function formatTsTypeRefName(typeName) {
  if (typeName?.type === "Identifier") return typeName.name;
  if (typeName?.type === "TSQualifiedName") {
    const right = typeName.right?.name;
    if (!right) return null;
    if (typeName.left?.type === "Identifier") return `${typeName.left.name}.${right}`;
    return null;
  }
  return null;
}

function isChildrenJacType(jacType) {
  return jacType === "any" || jacType.split(" | ").includes("any");
}

function childrenDefaultForParam(name, jacType, explicitDefault) {
  if (name !== "children" || explicitDefault) return explicitDefault;
  if (jacType.includes("None")) return "None";
  return null;
}

const PROPS_WRAPPER_TYPE_NAMES = new Set([
  "PropsWithChildren",
  "React.PropsWithChildren",
]);

/** Collect module-level `type` / `interface` declarations for props alias lookup. */
function collectTypeAliases(body) {
  const aliases = new Map();
  for (const item of body) {
    const decl = item?.type === "ExportNamedDeclaration" ? item.declaration : item;
    if (decl?.type === "TSTypeAliasDeclaration" && decl.id?.type === "Identifier") {
      aliases.set(decl.id.name, { kind: "alias", node: decl.typeAnnotation });
    } else if (decl?.type === "TSInterfaceDeclaration" && decl.id?.type === "Identifier") {
      aliases.set(decl.id.name, { kind: "interface", node: decl });
    }
  }
  return aliases;
}

function isSkippableTypeDeclaration(item) {
  const decl = item?.type === "ExportNamedDeclaration" ? item.declaration : item;
  return decl?.type === "TSTypeAliasDeclaration" || decl?.type === "TSInterfaceDeclaration";
}

/** Merge interface/type-literal members; later fields override earlier ones. */
function mergeTypeLiteralMembers(...memberLists) {
  const byKey = new Map();
  for (const members of memberLists) {
    for (const member of members ?? []) {
      const keyName = member.key?.name;
      if (keyName) byKey.set(keyName, member);
    }
  }
  return [...byKey.values()];
}

/** Lower a `interface` declaration to a synthetic `TSTypeLiteral` (V2.9). */
function interfaceDeclToTypeLiteral(ifaceDecl, typeAliases, path, diags, seen) {
  const memberLists = [];
  for (const ext of ifaceDecl.extends ?? []) {
    if (ext.type !== "TSExpressionWithTypeArguments") {
      diags.push(diag("E7221", `Unsupported interface extends form: ${ext.type}`, path));
      return null;
    }
    const params = ext.typeParameters?.params ?? [];
    if (params.length > 0) {
      diags.push(diag("E7221", "Generic interface extends are not supported for props alias resolution", path));
      return null;
    }
    const baseName = ext.expression?.type === "Identifier" ? ext.expression.name : null;
    if (!baseName) {
      diags.push(diag("E7221", "Qualified interface extends are not supported for props alias resolution", path));
      return null;
    }
    const baseLiteral = lookupTypeAliasLiteral(baseName, typeAliases, path, diags, seen);
    if (!baseLiteral) return null;
    memberLists.push(baseLiteral.members ?? []);
  }
  for (const member of ifaceDecl.body?.body ?? []) {
    if (member.type !== "TSPropertySignature") {
      diags.push(diag("E7221", `Unsupported interface member for props alias resolution: ${member.type}`, path));
      return null;
    }
    if (!member.key?.name) {
      diags.push(diag("E7221", "Computed interface keys are not supported for props alias resolution", path));
      return null;
    }
    memberLists.push([member]);
  }
  return { type: "TSTypeLiteral", members: mergeTypeLiteralMembers(...memberLists) };
}

/** Resolve a named module alias to an object type literal, or null on error. */
function lookupTypeAliasLiteral(name, typeAliases, path, diags, seen = new Set()) {
  if (seen.has(name)) {
    diags.push(diag("E7221", `Circular props type alias reference: ${name}`, path));
    return null;
  }
  const entry = typeAliases.get(name);
  if (!entry) return undefined;
  seen.add(name);
  let literal = null;
  if (entry.kind === "alias") {
    literal = resolvePropsTypeAnnotation(entry.node, typeAliases, path, diags, seen);
  } else {
    literal = interfaceDeclToTypeLiteral(entry.node, typeAliases, path, diags, seen);
  }
  seen.delete(name);
  return literal;
}

/**
 * Resolve a props annotation to an inline object type literal (V2.9). Returns the
 * literal node, or null when rejected. Unknown aliases push `E7221`.
 */
function resolvePropsTypeAnnotation(tsAnn, typeAliases, path, diags, seen = new Set()) {
  if (!tsAnn) return null;
  const kind = tsAnn.type ?? "";
  if (kind === "TSParenthesizedType") {
    return resolvePropsTypeAnnotation(tsAnn.typeAnnotation, typeAliases, path, diags, seen);
  }
  if (kind === "TSTypeLiteral") return tsAnn;
  if (kind !== "TSTypeReference") {
    diags.push(diag("E7221", `Props type must be an object type literal or resolvable alias (got ${kind})`, path));
    return null;
  }
  const refName = formatTsTypeRefName(tsAnn.typeName);
  if (!refName) {
    diags.push(diag("E7221", "Qualified props type references are not supported", path));
    return null;
  }
  if (PROPS_WRAPPER_TYPE_NAMES.has(refName)) {
    diags.push(diag(
      "E7221",
      "PropsWithChildren is not supported; use an inline object type with an optional children field",
      path,
    ));
    return null;
  }
  const params = tsAnn.typeParameters?.params ?? [];
  if (params.length > 0) {
    diags.push(diag(
      "E7221",
      `Generic props type ${refName}<...> is not supported unless ${refName} is a module type alias`,
      path,
    ));
    return null;
  }
  const resolved = lookupTypeAliasLiteral(refName, typeAliases, path, diags, seen);
  if (resolved === undefined) {
    diags.push(diag(
      "E7221",
      `Unknown props type alias '${refName}'; define it in the same module or use an inline object type`,
      path,
    ));
    return null;
  }
  return resolved;
}

function diag(code, message, path = "", details = {}) {
  return { code, message, path, category: "semantic", stage: "normalize", blocking: true, details };
}

function span(node) {
  const range = node?.range ?? [0, 0];
  const start = node?.loc?.start ?? {};
  return {
    byte_start: range[0] ?? 0,
    byte_end: range[1] ?? 0,
    line: start.line ?? 1,
    column: start.column ?? 0,
  };
}

function withOptionalJacType(jacType) {
  const parts = jacType.split(" | ").map((s) => s.trim());
  if (parts.includes("None")) return jacType;
  return `${jacType} | None`;
}

function joinUnionTypes(types) {
  const normalized = [];
  let hasNone = false;
  for (const t of types) {
    if (!t) continue;
    for (const part of t.split(" | ").map((s) => s.trim())) {
      if (part === "None") hasNone = true;
      else if (!normalized.includes(part)) normalized.push(part);
    }
  }
  if (hasNone) normalized.push("None");
  if (normalized.length === 0) return "None";
  if (normalized.length === 1) return normalized[0];
  return normalized.join(" | ");
}

function tsTypeToJac(typeNode, path, diags) {
  const kind = typeNode?.type ?? "";
  // A TypeScript type predicate (`value is Foo`) is a refinement annotation on
  // a boolean-returning function. Jac cannot express the refinement at the
  // signature boundary, but preserving the runtime result as `bool` is exact.
  if (kind === "TSTypePredicate") return "bool";
  if (kind === "TSStringKeyword") return "str";
  if (kind === "TSNumberKeyword") return "float";
  if (kind === "TSBooleanKeyword") return "bool";
  if (kind === "TSVoidKeyword") return "None";
  if (kind === "TSNullKeyword" || kind === "TSUndefinedKeyword") return "None";
  // V2.10 (Fix 4, Stage A): widen unmodeled TS types to Jac `any` in general type
  // positions (helper params, variable/return annotations, props FIELD types). `any`
  // is a sound widening for a type annotation — it never loses a binding name, only
  // type precision. NOTE: this does not affect props *alias* resolution, which is
  // handled by resolvePropsTypeAnnotation; an undefined props alias still rejects
  // (E7221) because it would lose the field names the props model requires.
  if (kind === "TSAnyKeyword" || kind === "TSUnknownKeyword") return "any";
  if (kind === "TSParenthesizedType") {
    return tsTypeToJac(typeNode.typeAnnotation, path, diags);
  }
  if (kind === "TSFunctionType") {
    return "any";
  }
  if (kind === "TSUnionType") {
    const parts = [];
    for (const t of typeNode.types ?? []) {
      if (t.type === "TSNullKeyword" || t.type === "TSUndefinedKeyword") {
        parts.push("None");
        continue;
      }
      const mapped = tsTypeToJac(t, path, diags);
      if (!mapped) return null;
      parts.push(mapped);
    }
    return joinUnionTypes(parts);
  }
  if (kind === "TSTypeLiteral") {
    // V2.12: Jac has no record/struct type — `{a: T, b: U}` in TYPE position
    // parses as a dict type with surprising key inference. Emit the explicit
    // dict type `dict[str, T | U]`; field access on dict-shaped values lowers to
    // subscripts (see noteDictBinding / usesDictBracketAccess).
    const valueTypes = [];
    for (const member of typeNode.members ?? []) {
      if (member.type !== "TSPropertySignature") {
        diags.push(diag("E7201", `Unsupported TypeScript property form: ${member.type}`, path));
        return null;
      }
      const keyName = member.key?.name;
      if (!keyName) {
        diags.push(diag("E7201", "Computed object type keys are not supported", path));
        return null;
      }
      const ann = member.typeAnnotation?.typeAnnotation;
      if (!ann) {
        diags.push(diag("E7201", "Missing property type annotation", path));
        return null;
      }
      const fieldType = tsTypeToJac(ann, path, diags);
      if (!fieldType) return null;
      valueTypes.push(member.optional ? withOptionalJacType(fieldType) : fieldType);
    }
    const uniq = [...new Set(valueTypes)];
    return `dict[str, ${uniq.join(" | ")}]`;
  }
  if (kind === "TSArrayType") {
    const elem = tsTypeToJac(typeNode.elementType, path, diags);
    if (!elem) return null;
    return `list[${elem}]`;
  }
  if (kind === "TSTupleType") {
    const types = typeNode.elementTypes ?? [];
    if (types.length === 0) {
      diags.push(diag("E7201", "Empty tuple types are not supported", path));
      return null;
    }
    const elems = [];
    for (const t of types) {
      if (t.type === "TSRestType") {
        diags.push(diag("E7201", "Rest tuple elements (...T[]) are not supported", path));
        return null;
      }
      const mapped = tsTypeToJac(t, path, diags);
      if (!mapped) return null;
      elems.push(mapped);
    }
    return `tuple[${elems.join(", ")}]`;
  }
  if (kind === "TSTypeReference") {
    const refName = formatTsTypeRefName(typeNode.typeName);
    if (!refName) {
      diags.push(diag("E7201", "Qualified type references are not supported", path));
      return null;
    }
    const params = typeNode.typeParameters?.params ?? [];
    if (refName === "Array" || refName === "ReadonlyArray") {
      if (params.length !== 1) {
        diags.push(diag("E7201", `${refName} requires exactly one type argument`, path));
        return null;
      }
      const elem = tsTypeToJac(params[0], path, diags);
      if (!elem) return null;
      return `list[${elem}]`;
    }
    if (CHILDREN_TS_TYPES.has(refName)) {
      if (params.length > 0) {
        diags.push(diag("E7201", `${refName} does not accept type arguments`, path));
        return null;
      }
      return "any";
    }
    if (refName === "PropsWithChildren") {
      diags.push(diag("E7201", "PropsWithChildren is not supported; use an inline object type", path));
      return null;
    }
    // A class declared in this module lowers to a Jac archetype with the same
    // name. Preserve that type so method calls on typed parameters remain
    // checker-visible instead of widening the whole value to `any`.
    if (params.length === 0 && LOCAL_CLASSES.has(refName)) return refName;
    // V2.10 (Fix 4, Stage A): unknown/unresolved type references and generic
    // references (e.g. `T`, `AbortSignal`, `Params`, `Foo<Bar>`) widen to `any`
    // rather than dropping the whole declaration. Sound for a type annotation.
    return "any";
  }
  // V2.10 (Fix 4, Stage A): any remaining unmodeled TS type kind in a type
  // position widens to `any` (sound) instead of dropping the declaration.
  return "any";
}

function isRefElementTypeName(refName) {
  if (REF_ELEMENT_TYPE_NAMES.has(refName)) return true;
  return /^HTML\w+Element$/.test(refName);
}

/**
 * Map a forwardRef ref-element generic (`HTMLButtonElement`, etc.) to Jac.
 */
function tsRefElementToJac(typeNode, path, diags) {
  const kind = typeNode?.type ?? "";
  if (kind === "TSParenthesizedType") {
    return tsRefElementToJac(typeNode.typeAnnotation, path, diags);
  }
  if (kind !== "TSTypeReference") {
    diags.push(diag("E7218", `Unsupported ref element type form: ${kind}`, path));
    return null;
  }
  const refName = formatTsTypeRefName(typeNode.typeName);
  if (!refName) {
    diags.push(diag("E7218", "Qualified ref element types are not supported", path));
    return null;
  }
  const params = typeNode.typeParameters?.params ?? [];
  if (params.length > 0) {
    diags.push(diag("E7218", `${refName} ref element type does not accept type arguments`, path));
    return null;
  }
  if (!isRefElementTypeName(refName)) {
    diags.push(diag("E7218", `Unsupported ref element type: ${refName}`, path));
    return null;
  }
  return refName;
}

/**
 * Extract the ref element from `ForwardedRef<T>` / `Ref<T>` on the ref parameter.
 */
function tsForwardedRefElementToJac(typeNode, path, diags) {
  const kind = typeNode?.type ?? "";
  if (kind === "TSParenthesizedType") {
    return tsForwardedRefElementToJac(typeNode.typeAnnotation, path, diags);
  }
  if (kind !== "TSTypeReference") return null;
  const refName = formatTsTypeRefName(typeNode.typeName);
  if (!refName || !FORWARDED_REF_TYPE_NAMES.has(refName)) return null;
  const params = typeNode.typeParameters?.params ?? [];
  if (params.length !== 1) {
    diags.push(diag("E7218", `${refName} requires exactly one type argument`, path));
    return null;
  }
  return tsRefElementToJac(params[0], path, diags);
}

function escapeJsxString(value) {
  return JSON.stringify(String(value))
    .slice(1, -1)
    .replace(/\u2028/g, "\\u2028")
    .replace(/\u2029/g, "\\u2029");
}

function fixedStringFromRegex(regex) {
  if (!regex || /[^guv]/.test(regex.flags ?? "")) return null;
  const pattern = regex.pattern ?? "";
  let out = "";
  for (let i = 0; i < pattern.length; i += 1) {
    const ch = pattern[i];
    if (ch !== "\\") {
      if (".^$*+?()[]{}|".includes(ch)) return null;
      out += ch;
      continue;
    }
    const next = pattern[++i];
    if (next === undefined) return null;
    const controls = { t: "\t", n: "\n", r: "\r", f: "\f", v: "\v", 0: "\0" };
    if (Object.prototype.hasOwnProperty.call(controls, next)) {
      out += controls[next];
    } else if (next === "x" && /^[0-9A-Fa-f]{2}$/.test(pattern.slice(i + 1, i + 3))) {
      out += String.fromCodePoint(Number.parseInt(pattern.slice(i + 1, i + 3), 16));
      i += 2;
    } else if (next === "u" && /^[0-9A-Fa-f]{4}$/.test(pattern.slice(i + 1, i + 5))) {
      out += String.fromCodePoint(Number.parseInt(pattern.slice(i + 1, i + 5), 16));
      i += 4;
    } else if ("\\/.^$*+?()[]{}|-".includes(next)) {
      out += next;
    } else {
      return null;
    }
  }
  return out;
}

function isJsxNode(n) {
  return n?.type === "JSXElement" || n?.type === "JSXFragment";
}

function isNullOrUndefinedExpr(n) {
  if (n === null || n === undefined) return true;
  if (n.type === "NullLiteral") return true;
  if (n.type === "Identifier" && n.name === "undefined") return true;
  if (n.type === "Literal" && n.value === null) return true;
  return false;
}

/** V2.5: lower a JSX-bearing conditional `{c ? <a/> : <b/>}` or logical
 * `{c && <a/>}` to its Jac form. Returns `undefined` when `expr` is not a
 * JSX-bearing conditional/logical (so the caller falls through to a plain
 * expression); the lowered source (without surrounding braces) on success; or
 * null with a diagnostic pushed on rejection.
 */
function parseJsxConditional(expr, path, diags, mappings) {
  if (!expr) return undefined;
  if (expr.type === "ConditionalExpression") {
    const consJsx = isJsxNode(expr.consequent);
    const altJsx = isJsxNode(expr.alternate);
    if (!consJsx && !altJsx) return undefined; // plain value ternary -> emitExpr
    const test = emitExpr(expr.test, path, diags);
    if (test === null) return null;
    const cons = consJsx
      ? parseJsxElement(expr.consequent, path, diags, mappings)
      : emitExpr(expr.consequent, path, diags);
    if (cons === null) return null;
    // `{c ? <a/> : null}` -> render-or-nothing idiom `c and <a/>`.
    if (isNullOrUndefinedExpr(expr.alternate)) {
      mappings.push({
        rule_id: "jsx.conditional.ternary-null.v2",
        mapping_class: "guarded",
        target: "ternary with null branch",
      });
      return `(${test} and ${cons})`;
    }
    const alt = altJsx
      ? parseJsxElement(expr.alternate, path, diags, mappings)
      : emitExpr(expr.alternate, path, diags);
    if (alt === null) return null;
    mappings.push({
      rule_id: "jsx.conditional.ternary.v2",
      mapping_class: "guarded",
      target: "jsx ternary",
    });
    return `(${cons} if ${test} else ${alt})`;
  }
  if (expr.type === "LogicalExpression") {
    if (!isJsxNode(expr.right)) return undefined;
    const op = LOGICAL_OPS[expr.operator];
    if (op === undefined) return undefined;
    const left = emitExpr(expr.left, path, diags);
    if (left === null) return null;
    const right = parseJsxElement(expr.right, path, diags, mappings);
    if (right === null) return null;
    mappings.push({
      rule_id: `jsx.conditional.${op}.v2`,
      mapping_class: "guarded",
      target: `jsx ${op} render`,
    });
    return `(${left} ${op} ${right})`;
  }
  return undefined;
}

function parseJsxAttribute(attr, path, diags) {
  if (attr?.type === "JSXSpreadAttribute") {
    diags.push(diag("E7202", "JSX spread attributes are not supported", path));
    return null;
  }
  if (attr?.type !== "JSXAttribute") {
    diags.push(diag("E7202", `Unsupported JSX attribute form: ${attr?.type}`, path));
    return null;
  }
  const nameNode = attr.name;
  if (nameNode?.type === "JSXNamespacedName") {
    diags.push(diag("E7202", "Namespaced JSX attributes are not supported", path));
    return null;
  }
  const name = nameNode?.name;
  if (!name) {
    diags.push(diag("E7202", "JSX attribute must have a simple name", path));
    return null;
  }
  const value = attr.value;
  if (!value) {
    return name;
  }
  if (value.type === "StringLiteral" || (value.type === "Literal" && typeof value.value === "string")) {
    return `${name}="${escapeJsxString(value.value)}"`;
  }
  if (value.type === "JSXExpressionContainer") {
    const exprText = emitExpr(value.expression, path, diags);
    if (exprText === null) return null;
    return `${name}={${exprText}}`;
  }
  diags.push(diag("E7202", `Unsupported JSX attribute value: ${value.type}`, path));
  return null;
}

/**
 * True when `node` is a non-optional, non-computed `<expr>.map(...)` call — the
 * only JSX child form lowered to a Jac list comprehension in this slice.
 */
function isMapCall(node) {
  return node?.type === "CallExpression"
    && !node.optional
    && node.callee?.type === "MemberExpression"
    && !node.callee.computed
    && !node.callee.optional
    && node.callee.property?.type === "Identifier"
    && node.callee.property.name === "map";
}

/**
 * Lower a JSX child `{xs.map(x => <li>{x}</li>)}` to a Jac list comprehension
 * `[<li>{x}</li> for x in xs]` (the W3042 idiom). The caller has already
 * confirmed `isMapCall(node)`. Guards — all fail-closed via E7217 so the dataset
 * never records a comprehension it cannot prove is order- and identity-preserving:
 *   - exactly one argument, an inline (non-async, non-generator) ArrowFunctionExpression
 *   - exactly one plain Identifier parameter (no index/second arg, no default/rest)
 *   - an expression body that is a single JSXElement
 *   - the iterable is a simple identifier or `a.b` member access
 * Multi-param/index callbacks and block/non-JSX bodies are rejected here; the
 * matrix defers multi-param INTEROP to a later slice. Stamps a GUARDED mapping
 * onto `mappings` on success. Returns the comprehension source (without the
 * surrounding JSX braces) or null with a diagnostic pushed.
 */
function emitMapComprehension(node, path, diags, mappings) {
  const args = node.arguments ?? [];
  if (args.length !== 1) {
    diags.push(diag("E7217", "JSX .map() comprehensions require exactly one callback argument", path));
    return null;
  }
  const cb = args[0];
  if (cb?.type !== "ArrowFunctionExpression") {
    diags.push(diag("E7217", "JSX .map() callback must be an inline arrow function", path));
    return null;
  }
  if (cb.async || cb.generator) {
    diags.push(diag("E7217", "JSX .map() async/generator callbacks are not supported", path));
    return null;
  }
  const params = cb.params ?? [];
  if (params.length !== 1 || params[0]?.type !== "Identifier") {
    diags.push(diag("E7217", "JSX .map() comprehensions require a single-parameter arrow (index/second parameters are not supported)", path));
    return null;
  }
  const itemName = params[0].name;
  if (cb.body?.type !== "JSXElement") {
    diags.push(diag("E7217", "JSX .map() callback must return a JSX element via an expression body", path));
    return null;
  }
  const iterText = emitExpr(node.callee.object, path, diags);
  if (iterText === null) return null;
  const elemText = parseJsxElement(cb.body, path, diags, mappings);
  if (elemText === null) return null;
  const compText = `[${elemText} for ${itemName} in ${iterText}]`;
  mappings.push({
    rule_id: "jsx.list.map-comprehension.v1",
    mapping_class: "guarded",
    target: compText,
  });
  return compText;
}

function parseJsxChild(child, path, diags, mappings) {
  if (child?.type === "JSXExpressionContainer") {
    if (isMapCall(child.expression)) {
      const compText = emitMapComprehension(child.expression, path, diags, mappings);
      if (compText === null) return null;
      return `{${compText}}`;
    }
    // V2.5: JSX-bearing ternary / && / || conditional rendering.
    const condText = parseJsxConditional(child.expression, path, diags, mappings);
    if (condText !== undefined) {
      if (condText === null) return null;
      return `{${condText}}`;
    }
    const exprText = emitExpr(child.expression, path, diags);
    if (exprText === null) return null;
    return `{${exprText}}`;
  }
  if (child?.type === "JSXElement") {
    return parseJsxElement(child, path, diags, mappings);
  }
  if (child?.type === "JSXText") {
    const text = (child.value ?? "").trim();
    return text;
  }
  if (child?.type === "JSXFragment") {
    diags.push(diag("E7202", "JSX fragments are not supported", path));
    return null;
  }
  diags.push(diag("E7202", `Unsupported JSX child: ${child?.type}`, path));
  return null;
}

function parseJsxElement(jsx, path, diags, mappings) {
  if (jsx?.type !== "JSXElement") {
    diags.push(diag("E7202", `Expected JSX element, got ${jsx?.type}`, path));
    return null;
  }
  const opening = jsx.openingElement;
  const tag = opening?.name;
  if (tag?.type !== "JSXIdentifier") {
    diags.push(diag("E7202", "Only intrinsic JSX tags are supported in V1", path));
    return null;
  }
  const attrTexts = [];
  for (const attr of opening.attributes ?? []) {
    const attrText = parseJsxAttribute(attr, path, diags);
    if (attrText === null) return null;
    if (attrText) attrTexts.push(attrText);
  }
  const attrPart = attrTexts.length ? ` ${attrTexts.join(" ")}` : "";
  const childTexts = [];
  for (const child of jsx.children ?? []) {
    const childText = parseJsxChild(child, path, diags, mappings);
    if (childText === null) return null;
    if (childText) childTexts.push(childText);
  }
  if (opening.selfClosing) {
    return `<${tag.name}${attrPart} />`;
  }
  return `<${tag.name}${attrPart}>${childTexts.join("")}</${tag.name}>`;
}

/**
 * Unwrap `React.FC<T>` / `FC<T>` on an export-const arrow component. Returns the
 * inner props type node when present; `isFc` marks recognized FC spellings.
 */
function unwrapFcPropsType(typeAnnotation, path, diags) {
  const ann = typeAnnotation?.typeAnnotation;
  if (!ann || ann.type !== "TSTypeReference") {
    return { propsType: null, isFc: false };
  }
  const refName = formatTsTypeRefName(ann.typeName);
  if (!refName) return { propsType: null, isFc: false };
  if (refName === "ComponentType" || refName === "React.ComponentType") {
    diags.push(diag("E7201", "ComponentType is not supported; use React.FC with an inline object type", path));
    return { propsType: null, isFc: true };
  }
  if (!FC_TYPE_NAMES.has(refName)) {
    return { propsType: null, isFc: false };
  }
  const params = ann.typeParameters?.params ?? [];
  if (params.length === 0) {
    return { propsType: null, isFc: true };
  }
  if (params.length !== 1) {
    diags.push(diag("E7201", `${refName} requires exactly one type argument`, path));
    return { propsType: null, isFc: true };
  }
  return { propsType: params[0], isFc: true };
}

/** Resolve a `memo` call callee (direct import or namespace member). */
function resolveMemoCallee(callee, hookBindings) {
  if (callee?.type === "Identifier") {
    const name = callee.name;
    if (hookBindings.aliases.get(name) === "memo") return true;
    return name === "memo";
  }
  if (callee?.type === "MemberExpression" && !callee.computed) {
    const obj = callee.object;
    const prop = callee.property;
    if (
      obj?.type === "Identifier"
      && prop?.type === "Identifier"
      && prop.name === "memo"
      && hookBindings.namespaces.has(obj.name)
    ) {
      return true;
    }
  }
  return false;
}

/**
 * Unwrap `memo(inner)` / `React.memo(inner)` on an export-const component.
 * Returns the inner init (an arrow or forwardRef call) so it composes with
 * FC/forwardRef handling. A custom props comparator (second argument) and a
 * non-component inner fail closed (E7219). A single type argument supplies the
 * props type as a lowest-precedence fallback (inline annotation wins).
 */
function unwrapMemoCall(init, path, diags, hookBindings) {
  if (init?.type !== "CallExpression") {
    return { isMemo: false };
  }
  if (!resolveMemoCallee(init.callee, hookBindings)) {
    return { isMemo: false };
  }
  const args = init.arguments ?? [];
  if (args.length !== 1) {
    diags.push(diag("E7219", "memo must wrap a single component callback (custom props comparators are not supported)", path));
    return { isMemo: true };
  }
  const inner = args[0];
  const isArrow = inner?.type === "ArrowFunctionExpression";
  const isForwardRef = inner?.type === "CallExpression"
    && resolveForwardRefCallee(inner.callee, hookBindings);
  if (!isArrow && !isForwardRef) {
    diags.push(diag("E7219", "memo must wrap an arrow function or forwardRef call", path));
    return { isMemo: true };
  }
  const typeParams = init.typeParameters?.params ?? [];
  let propsType = null;
  if (typeParams.length === 1) {
    propsType = typeParams[0];
  } else if (typeParams.length > 1) {
    diags.push(diag("E7219", "memo accepts at most one type argument", path));
    return { isMemo: true };
  }
  return { isMemo: true, inner, propsType };
}

/** Resolve a `forwardRef` call callee (direct import or namespace member). */
function resolveForwardRefCallee(callee, hookBindings) {
  if (callee?.type === "Identifier") {
    const name = callee.name;
    if (hookBindings.aliases.get(name) === "forwardRef") return true;
    return name === "forwardRef";
  }
  if (callee?.type === "MemberExpression" && !callee.computed) {
    const obj = callee.object;
    const prop = callee.property;
    if (
      obj?.type === "Identifier"
      && prop?.type === "Identifier"
      && prop.name === "forwardRef"
      && hookBindings.namespaces.has(obj.name)
    ) {
      return true;
    }
  }
  return false;
}

/**
 * Unwrap `forwardRef<T, P>(callback)` on an export-const component. Returns the
 * inner arrow callback and optional ref/props type nodes from generics.
 */
function unwrapForwardRefCall(init, path, diags, hookBindings) {
  if (init?.type !== "CallExpression") {
    return { isForwardRef: false };
  }
  if (!resolveForwardRefCallee(init.callee, hookBindings)) {
    return { isForwardRef: false };
  }
  const args = init.arguments ?? [];
  if (args.length !== 1 || args[0]?.type !== "ArrowFunctionExpression") {
    diags.push(diag("E7218", "forwardRef must wrap a single arrow function callback", path));
    return { isForwardRef: true };
  }
  const typeParams = init.typeParameters?.params ?? [];
  let refElementType = null;
  let propsType = null;
  if (typeParams.length > 0) {
    refElementType = tsRefElementToJac(typeParams[0], path, diags);
    if (!refElementType) return { isForwardRef: true };
    if (typeParams.length > 1) propsType = typeParams[1];
    if (typeParams.length > 2) {
      diags.push(diag("E7218", "forwardRef accepts at most two type arguments", path));
      return { isForwardRef: true };
    }
  }
  return {
    isForwardRef: true,
    callback: args[0],
    refElementType,
    propsType,
  };
}

function paramHasInlineType(param) {
  return Boolean(param?.typeAnnotation?.typeAnnotation);
}

function buildPropsTypeMap(tsAnn, typeAliases, path, diags) {
  const resolved = resolvePropsTypeAnnotation(tsAnn, typeAliases, path, diags);
  if (!resolved) return null;
  if (resolved.type !== "TSTypeLiteral") {
    diags.push(diag("E7204", "Destructured props require an inline object type annotation", path));
    return null;
  }
  const typeMap = new Map();
  for (const member of resolved.members ?? []) {
    if (member.type !== "TSPropertySignature") {
      diags.push(diag("E7201", `Unsupported TypeScript property form: ${member.type}`, path));
      return null;
    }
    const keyName = member.key?.name;
    if (!keyName) {
      diags.push(diag("E7201", "Computed object type keys are not supported", path));
      return null;
    }
    const ann = member.typeAnnotation?.typeAnnotation;
    if (!ann) {
      diags.push(diag("E7201", "Missing property type annotation", path));
      return null;
    }
    const fieldType = tsTypeToJac(ann, path, diags);
    if (!fieldType) return null;
    const finalType = member.optional ? withOptionalJacType(fieldType) : fieldType;
    typeMap.set(keyName, finalType);
  }
  return typeMap;
}

function parseDestructuredPropsParam(param, propsTypeNode, typeAliases, path, diags) {
  const typeMap = buildPropsTypeMap(propsTypeNode, typeAliases, path, diags);
  if (!typeMap) return null;
  const namedParams = [];
  const propNames = new Set();
  for (const prop of param.properties ?? []) {
    if (prop.type === "RestElement") {
      diags.push(diag("E7204", "Rest props destructuring is not supported in V1", path));
      return null;
    }
    if (prop.type !== "ObjectProperty" && prop.type !== "Property") {
      diags.push(diag("E7204", `Unsupported destructuring form: ${prop.type}`, path));
      return null;
    }
    if (prop.computed) {
      diags.push(diag("E7204", "Computed destructuring keys are not supported", path));
      return null;
    }
    const keyName = prop.key?.type === "Identifier" ? prop.key.name : null;
    const value = prop.value;
    let propName = null;
    let defaultText = null;
    if (value?.type === "AssignmentPattern") {
      const left = value.left;
      if (left?.type !== "Identifier") {
        diags.push(diag("E7204", "Nested destructuring is not supported", path));
        return null;
      }
      propName = left.name;
      defaultText = emitExpr(value.right, path, diags);
      if (defaultText === null) return null;
    } else if (value?.type === "Identifier") {
      if (keyName && value.name !== keyName) {
        diags.push(diag("E7204", "Destructuring rename is not supported", path));
        return null;
      }
      propName = value.name;
    } else {
      diags.push(diag("E7204", "Nested destructuring is not supported", path));
      return null;
    }
    if (!typeMap.has(propName)) {
      diags.push(diag("E7204", `Destructured prop '${propName}' has no type in the annotation`, path));
      return null;
    }
    const jacType = typeMap.get(propName);
    defaultText = childrenDefaultForParam(propName, jacType, defaultText);
    namedParams.push({ name: propName, type: jacType, default: defaultText });
    propNames.add(propName);
  }
  if (namedParams.length === 0) {
    diags.push(diag("E7204", "Destructured props must name at least one property", path));
    return null;
  }
  return { mode: "named", params: namedParams, propNames };
}

/**
 * Fail-open widening: build named `any` params straight from a destructuring
 * pattern's keys when the props *type* is missing or unmodelable (the prop names
 * are the pattern keys; only their types are lost, so widen those to `any`).
 * Bails (null) on the same hard forms parseDestructuredPropsParam rejects — rest,
 * nested, computed, rename — so those stay fail-closed.
 */
function namedParamsFromPattern(param, path) {
  const namedParams = [];
  const propNames = new Set();
  for (const prop of param.properties ?? []) {
    if (prop.type === "RestElement") return null;
    if ((prop.type !== "ObjectProperty" && prop.type !== "Property") || prop.computed) return null;
    const keyName = prop.key?.type === "Identifier" ? prop.key.name : null;
    const value = prop.value;
    let propName = null;
    let defaultText = null;
    if (value?.type === "AssignmentPattern") {
      if (value.left?.type !== "Identifier") return null;
      propName = value.left.name;
      defaultText = emitExpr(value.right, path, []);
      if (defaultText === null) return null;
    } else if (value?.type === "Identifier") {
      if (keyName && value.name !== keyName) return null; // rename
      propName = value.name;
    } else {
      return null;
    }
    defaultText = childrenDefaultForParam(propName, "any", defaultText);
    namedParams.push({ name: propName, type: "any", default: defaultText });
    propNames.add(propName);
  }
  if (namedParams.length === 0) return null;
  return { params: namedParams, propNames };
}

/**
 * Build named parameters from an inline object type literal (V1.16). Reuses the
 * V1.11 field map; per-field defaults are not available on a props bag, so only
 * `children` gains its conventional `= None`.
 */
function namedParamsFromInlineType(tsAnn, typeAliases, path, diags) {
  const typeMap = buildPropsTypeMap(tsAnn, typeAliases, path, diags);
  if (!typeMap) return null;
  if (typeMap.size === 0) {
    diags.push(diag("E7204", "Props object type must declare at least one field", path));
    return null;
  }
  const namedParams = [];
  const propNames = new Set();
  for (const [name, jacType] of typeMap) {
    namedParams.push({ name, type: jacType, default: childrenDefaultForParam(name, jacType, null) });
    propNames.add(name);
  }
  return { params: namedParams, propNames };
}

/**
 * Rewrite `bagName.field` member accesses in a component body to bare `field`
 * identifiers (V1.16), so a decomposed props bag lowers to idiomatic named-param
 * access — the only props form that type-checks in Jac. `fieldSet` is the known
 * prop-name set. Any other use of `bagName` (whole-object, computed index,
 * spread, nested/unknown field) fails closed with E7220.
 */
function rewritePropsAccess(node, bagName, fieldSet, path, diags, hookBindings) {
  if (!node || typeof node !== "object" || !bagName || fieldSet.size === 0) return;
  // V1.16: a whole-`props` useEffect dependency (`[props]`) expands to the full
  // field set (`[id, name, ...]`) — the equivalent named-param dependency list.
  if (node.type === "CallExpression" && hookBindings
    && resolveHookCallee(node.callee, hookBindings) === "useEffect") {
    const deps = node.arguments?.[1];
    if (deps?.type === "ArrayExpression") {
      const expanded = [];
      for (const el of deps.elements ?? []) {
        if (el?.type === "Identifier" && el.name === bagName) {
          for (const fieldName of fieldSet) expanded.push({ type: "Identifier", name: fieldName });
        } else {
          expanded.push(el);
        }
      }
      deps.elements = expanded;
    }
  }
  if (Array.isArray(node)) {
    for (const child of node) {
      if (child?.type === "Identifier" && child.name === bagName) {
        diags.push(diag("E7220", `props bag '${bagName}' must be used only via known field access (e.g. ${bagName}.field); whole-object, computed, spread, or unknown-field use cannot be decomposed`, path));
      }
      rewritePropsAccess(child, bagName, fieldSet, path, diags, hookBindings);
    }
    return;
  }
  for (const key of Object.keys(node)) {
    if (key === "loc" || key === "range" || key === "start" || key === "end") continue;
    const child = node[key];
    if (!child || typeof child !== "object") continue;
    if (child.type === "Identifier" && child.name === bagName) {
      const allowed = node.type === "MemberExpression"
        && !node.computed
        && node.object === child
        && node.property?.type === "Identifier"
        && fieldSet.has(node.property.name);
      if (!allowed) {
        diags.push(diag("E7220", `props bag '${bagName}' must be used only via known field access (e.g. ${bagName}.field); whole-object, computed, spread, or unknown-field use cannot be decomposed`, path));
      }
    }
    rewritePropsAccess(child, bagName, fieldSet, path, diags, hookBindings);
  }
  if (node.type === "MemberExpression"
    && !node.computed
    && node.object?.type === "Identifier"
    && node.object.name === bagName
    && node.property?.type === "Identifier"
    && fieldSet.has(node.property.name)) {
    const fieldName = node.property.name;
    node.type = "Identifier";
    node.name = fieldName;
    delete node.object;
    delete node.property;
    delete node.computed;
    delete node.optional;
  }
}

function parseComponentParam(params, path, diags, externalPropsType = null, typeAliases = null, failOpen = false) {
  const aliases = typeAliases ?? new Map();
  // V1.2: zero props; V1: one props-bag identifier; V1.11: one destructuring pattern.
  if (params.length === 0) {
    return { mode: "props", name: "", type: "" };
  }
  if (params.length !== 1) {
    diags.push(diag("E7204", "V1 supports zero or one component parameter", path));
    return null;
  }
  const param = params[0];
  const tsAnn = param.typeAnnotation?.typeAnnotation ?? externalPropsType;
  if (param.type === "ObjectPattern") {
    if (!tsAnn) {
      if (failOpen) {
        const widened = namedParamsFromPattern(param, path);
        if (widened) return { mode: "named", params: widened.params, propNames: widened.propNames };
      }
      diags.push(diag("E7204", "Destructured props require an inline object type annotation", path));
      return null;
    }
    const localD = [];
    const destr = parseDestructuredPropsParam(param, tsAnn, aliases, path, localD);
    if (destr) return destr;
    // Unmodelable props type on a destructured param: under fail-open, synthesize
    // named `any` params from the destructuring keys (the prop names are the
    // pattern keys — the type only supplied their types, which we widen to any).
    if (failOpen) {
      const widened = namedParamsFromPattern(param, path);
      if (widened) return { mode: "named", params: widened.params, propNames: widened.propNames };
    }
    diags.push(...localD);
    return null;
  }
  if (param.type !== "Identifier") {
    diags.push(diag("E7204", "V1 supports a props identifier or destructured props object", path));
    return null;
  }
  // V1.16 / V2.9: a props-bag identifier with an inline or resolved object type
  // decomposes into named parameters (the idiomatic, type-checking Jac form).
  if (tsAnn) {
    const localD = [];
    const resolved = resolvePropsTypeAnnotation(tsAnn, aliases, path, localD);
    if (!resolved) {
      // Unmodelable props type (React.ComponentProps<...>, HTMLAttributes,
      // intersection, qualified ref). Under fail-open, widen to an open props
      // bag typed `any` instead of dropping the component — `.field` access on
      // `any` type-checks. Strict mode keeps the original E7221 reject.
      if (failOpen) return { mode: "props", name: param.name, type: "any" };
      diags.push(...localD);
      return null;
    }
    if (resolved.type === "TSTypeLiteral") {
      const named = namedParamsFromInlineType(resolved, aliases, path, diags);
      if (!named) return null;
      return { mode: "named", params: named.params, propNames: named.propNames, bagName: param.name };
    }
  }
  let paramType = "dict";
  if (tsAnn) {
    const mapped = tsTypeToJac(tsAnn, path, diags);
    if (!mapped) return null;
    paramType = mapped;
  }
  return { mode: "props", name: param.name, type: paramType };
}

function parseForwardRefParams(params, path, diags, externalPropsType, refElementType, typeAliases = null, failOpen = false) {
  if (params.length !== 2) {
    diags.push(diag("E7218", "forwardRef callback must have exactly two parameters (props, ref)", path));
    return null;
  }
  const refParam = params[1];
  if (refParam.type !== "Identifier" || refParam.name !== "ref") {
    diags.push(diag("E7218", "forwardRef trailing parameter must be named ref", path));
    return null;
  }
  let refElem = refElementType;
  if (!refElem) {
    refElem = tsForwardedRefElementToJac(refParam.typeAnnotation?.typeAnnotation, path, diags);
  }
  if (!refElem) {
    diags.push(diag(
      "E7218",
      "forwardRef requires a ref element type (generic argument or ref parameter annotation)",
      path,
    ));
    return null;
  }
  const propsSig = parseComponentParam([params[0]], path, diags, externalPropsType, typeAliases, failOpen);
  if (!propsSig) return null;
  propsSig.refParam = { name: "ref", type: `Ref[${refElem}]` };
  return propsSig;
}

function propContextFromSig(sig) {
  if (sig.mode === "named") {
    return { mode: "named", propNames: sig.propNames };
  }
  return { mode: "props", propParamName: sig.name };
}

/**
 * Emit a hook-side expression (useState initializer, setter argument, call
 * argument, interop call) as Jac source. Returns null and pushes E7215 on any
 * node this slice does not lower, so unsupported expressions never silently
 * reach the dataset.
 */
/** V2.4: emit a TS object literal as a Jac dict. Keys are quoted strings so the
 * spelling is preserved exactly; `...spread` becomes `**spread` (the Jac dict
 * spread form). Methods, getters, setters, computed keys, and numeric keys are
 * rejected (E7215) until a dedicated object-semantics slice proves equivalence.
 * Returns the dict source (without surrounding braces) or null with a diag.
 */
function emitObjectLiteral(node, path, diags, ctx = {}) {
  const parts = [];
  for (const prop of node.properties ?? []) {
    if (prop.type === "SpreadElement") {
      const val = emitExpr(prop.argument, path, diags, ctx);
      if (val === null) return null;
      parts.push(`**${val}`);
      continue;
    }
    if (prop.type !== "ObjectProperty" && prop.type !== "Property") {
      diags.push(diag("E7215", `Unsupported object member form: ${prop.type} (methods/getters are not supported)`, path));
      return null;
    }
    if (prop.computed) {
      // Fix 5: a computed key whose expression is itself emittable (enum member
      // ref `[SummaryKeys.Confirmed]`, identifier, literal) lowers to a Jac dict
      // with an expression key `{SummaryKeys.Confirmed: ...}`. Non-emittable keys
      // (calls, etc.) still fail via emitExpr's null return.
      const keyExpr = emitExpr(prop.key, path, diags, ctx);
      if (keyExpr === null) return null;
      const cval = emitExpr(prop.value, path, diags, ctx);
      if (cval === null) return null;
      parts.push(`${keyExpr}: ${cval}`);
      continue;
    }
    if (prop.shorthand) {
      // { x } -> {"x": x}
      const name = prop.key?.name;
      if (!name) {
        diags.push(diag("E7215", "Shorthand object property must have a simple name", path));
        return null;
      }
      const val = emitExpr(prop.value, path, diags, ctx);
      if (val === null) return null;
      parts.push(`"${name}": ${val}`);
      continue;
    }
    let keyText;
    const key = prop.key;
    if (key?.type === "Identifier") keyText = `"${key.name}"`;
    else if (key?.type === "StringLiteral" || (key?.type === "Literal" && typeof key.value === "string")) {
      keyText = `"${escapeJsxString(key.value)}"`;
    } else if (key?.type === "NumericLiteral" || (key?.type === "Literal" && typeof key.value === "number")) {
      keyText = String(key.value);
    } else {
      diags.push(diag("E7215", `Unsupported object key form: ${key?.type}`, path));
      return null;
    }
    const val = emitExpr(prop.value, path, diags, ctx);
    if (val === null) return null;
    parts.push(`${keyText}: ${val}`);
  }
  return parts.join(", ");
}

/** V2.4: emit a TS template literal as a Jac f-string. Uses the raw quasi text
 * (preserving source escapes like \n), doubles literal braces, and inlines each
 * expression via emitExpr. Returns `f"..."` or null with a diag.
 */
function emitTemplateLiteral(node, path, diags, ctx = {}) {
  const quasis = node.quasis ?? [];
  const exprs = node.expressions ?? [];
  let body = "";
  for (let i = 0; i < quasis.length; i++) {
    const raw = (quasis[i]?.value?.raw ?? "")
      .replace(/\\/g, "\\\\")
      .replace(/"/g, '\\"')
      .replace(/\{/g, "{{")
      .replace(/\}/g, "}}");
    body += raw;
    if (i < exprs.length) {
      const text = emitExpr(exprs[i], path, diags, ctx);
      if (text === null) return null;
      body += `{${text}}`;
    }
  }
  return `f"${body}"`;
}

/** V2.7: emit an arrow/function expression as a Jac callback lambda. Parameters
 * carry Jac types (TS annotation when present, else `any` with a recorded note so
 * the widening is never silent). Returns `lambda (...) -> ret { ... }` or null.
 * `widenedParams` (out) collects param names widened to `any` for the caller to
 * stamp as interop evidence.
 */
function emitCallbackLambda(node, path, diags, widenedParams = null, parentCtx = {}) {
  if (node.generator || node.async) {
    diags.push(diag("E7215", "Async/generator callbacks are not supported", path));
    return null;
  }
  const lambdaCtx = {
    path,
    diags,
    inLambda: true,
    dictBindings: new Set(),
    dictListBindings: new Set(),
    dictListFieldTypes: new Map(),
    dictFieldTypes: new Map(),
    inClass: parentCtx.inClass ?? false,
    className: parentCtx.className,
    staticHoists: parentCtx.staticHoists,
    allowReturn: true,
    failOpen: parentCtx.failOpen ?? false,
    droppedStatements: parentCtx.droppedStatements ?? [],
    floatLocals: collectFloatLocals(node.body),
  };
  const paramParts = [];
  for (const param of node.params ?? []) {
    if (param.type === "AssignmentPattern") {
      // default value: (x = 1) -> keep type from annotation or any; default dropped
      if (param.left?.type !== "Identifier") {
        diags.push(diag("E7215", "Callback default parameters must be simple identifiers", path));
        return null;
      }
      let jacType = "any";
      const ann = param.left.typeAnnotation?.typeAnnotation;
      if (ann) {
        const mapped = tsTypeToJac(ann, path, diags);
        if (!mapped) return null;
        jacType = mapped;
      } else if (widenedParams) widenedParams.push(param.left.name);
      paramParts.push(`${identText(param.left.name)}: ${jacType}`);
      continue;
    }
    if (param.type === "RestElement") {
      diags.push(diag("E7215", "Rest parameters in callbacks are not supported", path));
      return null;
    }
    if (param.type !== "Identifier") {
      diags.push(diag("E7215", `Unsupported callback parameter form: ${param.type}`, path));
      return null;
    }
    let jacType = "any";
    const ann = param.typeAnnotation?.typeAnnotation;
    if (ann) {
      const mapped = tsTypeToJac(ann, path, diags);
      if (!mapped) return null;
      jacType = mapped;
    } else if (widenedParams) widenedParams.push(param.name);
    paramParts.push(`${identText(param.name)}: ${jacType}`);
  }
  const paramText = paramParts.join(", ");
  const stmts = [];
  if (node.body?.type === "BlockStatement") {
    for (const s of node.body.body ?? []) {
      const lines = emitStatement(s, lambdaCtx);
      if (lines === null) return null;
      stmts.push(...lines);
    }
  } else {
    const val = emitExpr(node.body, path, diags, lambdaCtx);
    if (val === null) return null;
    stmts.push(`return ${val};`);
  }
  const bodyText = stmts.length ? ` ${stmts.join(" ")} ` : "";
  return `lambda (${paramText}) -> any {${bodyText}}`;
}

/** V2.8: track dict-typed bindings so `d.field` lowers to `d["field"]`. */
function noteDictBinding(name, init, ann, ctx) {
  if (!name || !ctx?.dictBindings) return;
  if (init?.type === "NewExpression" && init.callee?.type === "Identifier"
    && init.callee.name === "Map") {
    ctx.mapBindings ??= new Set();
    ctx.mapBindings.add(name);
  }
  if (init?.type === "ObjectExpression") {
    ctx.dictBindings.add(name);
    return;
  }
  if (ann?.type === "TSTypeLiteral") ctx.dictBindings.add(name);
  const dictElement = ann?.type === "TSArrayType"
    ? ann.elementType
    : (ann?.type === "TSTypeReference" && ["Array", "ReadonlyArray"].includes(formatTsTypeRefName(ann.typeName))
      ? ann.typeParameters?.params?.[0]
      : null);
  if (dictElement?.type === "TSTypeLiteral") {
    ctx.dictListBindings ??= new Set();
    ctx.dictListBindings.add(name);
    const fieldTypes = new Map();
    for (const member of dictElement.members ?? []) {
      if (member.type !== "TSPropertySignature" || member.key?.type !== "Identifier") continue;
      const fieldType = tsTypeToJac(member.typeAnnotation?.typeAnnotation, ctx.path, ctx.diags);
      if (fieldType) fieldTypes.set(member.key.name, member.optional ? withOptionalJacType(fieldType) : fieldType);
    }
    ctx.dictListFieldTypes ??= new Map();
    ctx.dictListFieldTypes.set(name, fieldTypes);
  }
  // V2.12: a call to a function whose TS return type is an object literal type
  // produces a dict value (see DICT_RETURNING_FUNCS).
  if (init?.type === "CallExpression" && init.callee?.type === "Identifier"
    && DICT_RETURNING_FUNCS.has(init.callee.name)) {
    ctx.dictBindings.add(name);
    const fieldTypes = DICT_RETURN_FIELD_TYPES.get(init.callee.name);
    if (fieldTypes) ctx.dictFieldTypes?.set(name, fieldTypes);
  }
}

function isDictBinding(name, ctx) {
  return Boolean(name && ctx?.dictBindings?.has(name));
}

function isKnownMapReceiver(node, ctx = {}) {
  return node?.type === "Identifier"
    && (ctx.mapBindings?.has(node.name) || MODULE_MAP_BINDINGS.has(node.name));
}

function usesDictBracketAccess(node, ctx) {
  if (node.computed) return false;
  if (node.object?.type === "ObjectExpression") return true;
  if (node.object?.type === "Identifier" && isDictBinding(node.object.name, ctx)) return true;
  // V2.12: direct member access on a dict-returning call: `f().field`.
  if (node.object?.type === "CallExpression" && node.object.callee?.type === "Identifier"
    && DICT_RETURNING_FUNCS.has(node.object.callee.name)) return true;
  return false;
}

/** V2.8: lower `.map(cb)` in expression position to a list comprehension when the
 * callback is a single-parameter inline arrow with an expression (or single-return
 * block) body. Returns the comprehension source, `undefined` when not applicable,
 * or null on failure. */
function tryEmitExprMapComprehension(node, path, diags, ctx) {
  if (!isMapCall(node)) return undefined;
  const args = node.arguments ?? [];
  if (args.length !== 1) return undefined;
  const cb = args[0];
  if (cb?.type !== "ArrowFunctionExpression" || cb.async || cb.generator) return undefined;
  const params = cb.params ?? [];
  if (params.length !== 1 || params[0]?.type !== "Identifier") return undefined;
  const itemName = params[0].name;
  let bodyExpr = null;
  if (cb.body?.type === "BlockStatement") {
    const stmts = cb.body.body ?? [];
    if (stmts.length !== 1 || stmts[0]?.type !== "ReturnStatement") return undefined;
    bodyExpr = stmts[0].argument;
  } else {
    bodyExpr = cb.body;
  }
  if (!bodyExpr) return undefined;
  const iterText = emitExpr(node.callee.object, path, diags, ctx);
  if (iterText === null) return null;
  const callbackCtx = { ...ctx, dictBindings: new Set(ctx?.dictBindings ?? []) };
  if (node.callee.object?.type === "Identifier"
    && ctx?.dictListBindings?.has(node.callee.object.name)) {
    callbackCtx.dictBindings.add(itemName);
    const fieldTypes = ctx.dictListFieldTypes?.get(node.callee.object.name);
    if (fieldTypes) {
      callbackCtx.dictFieldTypes = new Map(ctx.dictFieldTypes ?? []);
      callbackCtx.dictFieldTypes.set(itemName, fieldTypes);
    }
  }
  const bodyText = emitExpr(bodyExpr, path, diags, callbackCtx);
  if (bodyText === null) return null;
  return `[${bodyText} for ${itemName} in ${iterText}]`;
}

/** V2.8: Jac-native call lowering — `.push` -> `.append`, `arr.join(sep)` ->
 * `sep.join(arr)`, and expression `.map` -> list comprehension. Returns the
 * lowered source, `undefined` when not applicable, or null on failure. */
function tryEmitJacNativeCall(node, path, diags, ctx) {
  const mapText = tryEmitExprMapComprehension(node, path, diags, ctx);
  if (mapText !== undefined) return mapText;
  if (node.callee?.type !== "MemberExpression" || node.callee.computed || node.callee.optional) {
    return undefined;
  }
  const method = node.callee.property?.type === "Identifier" ? node.callee.property.name : null;
  if (!method) return undefined;
  if (method === "sort" && (node.arguments ?? []).length === 1) {
    const callback = node.arguments[0];
    if (callback?.type === "ArrowFunctionExpression" && !callback.async && !callback.generator
      && callback.params?.length === 2
      && callback.params[0]?.type === "Identifier" && callback.params[1]?.type === "Identifier") {
      let comparison = callback.body;
      if (comparison?.type === "BlockStatement") {
        const statements = comparison.body ?? [];
        comparison = statements.length === 1 && statements[0]?.type === "ReturnStatement"
          ? statements[0].argument
          : null;
      }
      const left = comparison?.type === "BinaryExpression" && comparison.operator === "-"
        ? comparison.left
        : null;
      const right = left ? comparison.right : null;
      const memberName = (expr, param) => expr?.type === "MemberExpression" && !expr.computed
        && expr.object?.type === "Identifier" && expr.object.name === param
        && expr.property?.type === "Identifier"
        ? expr.property.name
        : null;
      const a = callback.params[0].name;
      const b = callback.params[1].name;
      const ascending = memberName(left, a);
      const descending = memberName(left, b);
      const property = ascending && memberName(right, b) === ascending
        ? ascending
        : (descending && memberName(right, a) === descending ? descending : null);
      if (property) {
        const recv = emitExpr(node.callee.object, path, diags, ctx);
        if (recv === null) return null;
        const reverse = property === descending ? ", reverse=True" : "";
        return `${recv}.sort(key=lambda (_jx_sort: any) -> any { return _jx_sort["${property}"]; }${reverse})`;
      }
    }
  }
  // `x.toString()` -> Jac `str(x)`. Only the no-arg form; a radix arg
  // (`n.toString(16)`) has no clean Jac equivalent and falls through to diagnose.
  if (method === "toString" && (node.arguments ?? []).length === 0) {
    const recv = emitExpr(node.callee.object, path, diags, ctx);
    if (recv === null) return null;
    return `str(${recv})`;
  }
  // No sound Jac form: diagnose so fail-open drops the expression instead of
  // emitting Jac that silently fails the type checker and sinks the whole file.
  if (JS_UNSUPPORTED_NUMBER_METHODS.has(method)) {
    diags.push(diag("E7215", `JS \`.${method}()\` has no Jac equivalent`, path));
    return null;
  }
  // JS string/array index & slice idioms -> native Jac subscript/slice syntax.
  // `s.charAt(i)` -> `s[i]`; `s.slice(a[,b])` / `s.substring(a[,b])` -> `s[a:b]`;
  // `x.includes(v)` -> `(v in x)` (works for str and list). Emitting the raw
  // method fails the checker (no such attribute) and sinks the file.
  if (method === "charAt" && (node.arguments ?? []).length === 1) {
    const recv = emitExpr(node.callee.object, path, diags, ctx);
    if (recv === null) return null;
    const idx = emitExpr(node.arguments[0], path, diags, ctx);
    if (idx === null) return null;
    return `${recv}[${idx}]`;
  }
  // V2.12: `s.charCodeAt(i)` / `s.codePointAt(i)` -> `ord(s[i])` (codePointAt
  // surrogate-pair semantics are not modeled; mapping note).
  if ((method === "charCodeAt" || method === "codePointAt")
      && (node.arguments ?? []).length <= 1) {
    const recv = emitExpr(node.callee.object, path, diags, ctx);
    if (recv === null) return null;
    let idx = "0";
    if ((node.arguments ?? []).length === 1) {
      idx = emitExpr(node.arguments[0], path, diags, ctx);
      if (idx === null) return null;
    }
    return `ord(${recv}[${idx}])`;
  }
  // V2.12: `xs.every(cb)` / `xs.some(cb)` -> `all(...)` / `any(...)` over a
  // generator expression, for single-param inline arrows (expression body or
  // single-return block) — mirroring the `.map` comprehension guard set.
  if ((method === "every" || method === "some") && (node.arguments ?? []).length === 1) {
    const cb = node.arguments[0];
    if (cb?.type === "ArrowFunctionExpression" && !cb.async && !cb.generator
      && (cb.params ?? []).length === 1 && cb.params[0]?.type === "Identifier") {
      const itemName = cb.params[0].name;
      let bodyExpr = cb.body?.type === "BlockStatement" ? null : cb.body;
      if (cb.body?.type === "BlockStatement") {
        const stmts = cb.body.body ?? [];
        if (stmts.length === 1 && stmts[0].type === "ReturnStatement" && stmts[0].argument) {
          bodyExpr = stmts[0].argument;
        }
      }
      if (bodyExpr) {
        const recv = emitExpr(node.callee.object, path, diags, ctx);
        if (recv === null) return null;
        const cond = emitExpr(bodyExpr, path, diags, ctx);
        if (cond === null) return null;
        const fn = method === "every" ? "all" : "any";
        return `${fn}(${cond} for ${identText(itemName)} in ${recv})`;
      }
    }
  }
  if ((method === "slice" || method === "substring")
      && (node.arguments ?? []).length >= 1 && node.arguments.length <= 2) {
    const recv = emitExpr(node.callee.object, path, diags, ctx);
    if (recv === null) return null;
    const a = emitExpr(node.arguments[0], path, diags, ctx);
    if (a === null) return null;
    let b = "";
    if (node.arguments.length === 2) {
      b = emitExpr(node.arguments[1], path, diags, ctx);
      if (b === null) return null;
    }
    return `${recv}[${a}:${b}]`;
  }
  if (method === "split" && (node.arguments ?? []).length === 1) {
    const pattern = node.arguments[0];
    const literalRegex = pattern?.type === "Literal" && pattern.regex;
    const regexConst = pattern?.type === "Identifier" && REGEX_CONSTS.has(pattern.name);
    if (literalRegex || regexConst) {
      const recv = emitExpr(node.callee.object, path, diags, ctx);
      if (recv === null) return null;
      const patText = literalRegex ? pyRawString(pattern.regex.pattern ?? "") : identText(pattern.name);
      const flagArg = literalRegex ? pyRegexFlagsArg(pattern.regex.flags) : "";
      REGEX_INTEROP.split = true;
      return flagArg
        ? `split(${patText}, ${recv}, 0${flagArg})`
        : `split(${patText}, ${recv})`;
    }
  }
  // V2.12: `s.replace(regexOrRegexConst, repl)` -> `sub(pat, repl, s)`. Only
  // the regex first-arg form (literal or module regex-const); a string first
  // arg (replace-all vs first-only) diverges and stays unsupported.
  if (method === "replace" && (node.arguments ?? []).length === 2) {
    const a0 = node.arguments[0];
    const replacement = node.arguments[1];
    const replacementValue = replacement?.type === "Literal" || replacement?.type === "StringLiteral"
      ? replacement.value
      : null;
    const fixed = a0?.type === "Literal" && a0.regex
      ? fixedStringFromRegex(a0.regex)
      : null;
    if (fixed !== null && typeof replacementValue === "string" && !replacementValue.includes("$")) {
      const recv = emitExpr(node.callee.object, path, diags, ctx);
      if (recv === null) return null;
      const oldText = `"${escapeJsxString(fixed)}"`;
      const replText = `"${escapeJsxString(replacementValue)}"`;
      return a0.regex.flags?.includes("g")
        ? `${recv}.replace(${oldText}, ${replText})`
        : `${recv}.replace(${oldText}, ${replText}, 1)`;
    }
    const isRegex = (a0?.type === "Literal" && a0.regex)
      || (a0?.type === "Identifier" && REGEX_CONSTS.has(a0.name));
    if (isRegex) {
      const patText = a0.type === "Literal" ? pyRawString(a0.regex.pattern ?? "") : a0.name;
      const flagArg = a0.type === "Literal" ? pyRegexFlagsArg(a0.regex.flags) : "";
      const recv = emitExpr(node.callee.object, path, diags, ctx);
      if (recv === null) return null;
      const repl = emitExpr(node.arguments[1], path, diags, ctx);
      if (repl === null) return null;
      REGEX_INTEROP.sub = true;
      return `sub(${patText}, ${repl}, ${recv}${flagArg})`;
    }
  }
  // V2.13: `s.repeat(n)` -> `(s * int(n))`. TS `number` maps to Jac float,
  // while sequence multiplication requires an integer count.
  if (method === "repeat" && (node.arguments ?? []).length === 1) {
    const recv = emitExpr(node.callee.object, path, diags, ctx);
    if (recv === null) return null;
    const n = emitExpr(node.arguments[0], path, diags, ctx);
    if (n === null) return null;
    return `(${recv} * int(${n}))`;
  }
  if (method === "includes" && (node.arguments ?? []).length === 1) {
    const recv = emitExpr(node.callee.object, path, diags, ctx);
    if (recv === null) return null;
    const val = emitExpr(node.arguments[0], path, diags, ctx);
    if (val === null) return null;
    return `(${val} in ${recv})`;
  }
  // V2.13: preserve JS's -1-on-miss behavior. The conditional repeats its
  // operands, so accept only stable expressions; calls/updates fail closed.
  if (method === "indexOf" && (node.arguments ?? []).length === 1) {
    if (!isStableRepeatableExpr(node.callee.object) || !isStableRepeatableExpr(node.arguments[0])) {
      diags.push(diag("E7215", "indexOf receiver and value must be side-effect-free", path));
      return null;
    }
    const recv = emitExpr(node.callee.object, path, diags, ctx);
    if (recv === null) return null;
    const val = emitExpr(node.arguments[0], path, diags, ctx);
    if (val === null) return null;
    return `(-1 if ${val} not in ${recv} else ${recv}.index(${val}))`;
  }
  // `splice` returns the removed elements in JS, so it cannot lower as a Jac
  // expression. emitStatement handles the discard-result two-argument form.
  if (method === "splice") {
    diags.push(diag("E7215", "splice is supported only as a discard-result statement", path));
    return null;
  }
  // V2.12: `xs.filter(cb)` -> `[x for x in xs if cb(x)]` (single-param inline
  // arrow, expression or single-return body).
  if (method === "filter" && (node.arguments ?? []).length === 1) {
    const cb = node.arguments[0];
    if (cb?.type === "ArrowFunctionExpression" && !cb.async && !cb.generator
      && (cb.params ?? []).length === 1 && cb.params[0]?.type === "Identifier") {
      let bodyExpr = cb.body?.type === "BlockStatement" ? null : cb.body;
      if (cb.body?.type === "BlockStatement") {
        const stmts = cb.body.body ?? [];
        if (stmts.length === 1 && stmts[0].type === "ReturnStatement" && stmts[0].argument) {
          bodyExpr = stmts[0].argument;
        }
      }
      if (bodyExpr) {
        const recv = emitExpr(node.callee.object, path, diags, ctx);
        if (recv === null) return null;
        const cond = emitExpr(bodyExpr, path, diags, ctx);
        if (cond === null) return null;
        return `[${identText(cb.params[0].name)} for ${identText(cb.params[0].name)} in ${recv} if ${cond}]`;
      }
    }
  }
  if (method === "push") {
    const recv = emitExpr(node.callee.object, path, diags, ctx);
    if (recv === null) return null;
    const arg = node.arguments?.[0];
    if (!arg) return undefined;
    const argText = emitExpr(arg, path, diags, ctx);
    if (argText === null) return null;
    return `${recv}.append(${argText})`;
  }
  if (method === "join") {
    const recv = emitExpr(node.callee.object, path, diags, ctx);
    if (recv === null) return null;
    const sepArg = node.arguments?.[0];
    if (!sepArg) return undefined;
    const sepText = emitExpr(sepArg, path, diags, ctx);
    if (sepText === null) return null;
    return `${sepText}.join(${recv})`;
  }
  const jacMethod = JS_STRING_METHODS[method];
  if (jacMethod) {
    const recv = emitExpr(node.callee.object, path, diags, ctx);
    if (recv === null) return null;
    const args = [];
    for (const arg of node.arguments ?? []) {
      const text = emitExpr(arg, path, diags, ctx);
      if (text === null) return null;
      args.push(text);
    }
    return `${recv}.${jacMethod}(${args.join(", ")})`;
  }
  return undefined;
}

/** Expressions safe to repeat in a conditional lowering without changing JS
 * evaluation count. Calls, updates, assignments, and optional reads are not. */
function isStableRepeatableExpr(node) {
  return (node?.type === "ChainExpression" && isStableRepeatableExpr(node.expression))
    || (node?.type === "MetaProperty" && node.meta?.name === "import" && node.property?.name === "meta")
    || node?.type === "Identifier" || node?.type === "ThisExpression"
    || node?.type === "Literal"
    || ((node?.type === "MemberExpression" || node?.type === "OptionalMemberExpression")
      && isStableRepeatableExpr(node.object)
      && (!node.computed || isStableRepeatableExpr(node.property)))
    || ((node?.type === "BinaryExpression" || node?.type === "LogicalExpression")
      && node.operator !== "??"
      && isStableRepeatableExpr(node.left) && isStableRepeatableExpr(node.right));
}

/** V2.4: emit a member access, supporting `a.b` and computed `a[expr]`. Optional
 * chaining (`?.`) is rejected because its short-circuit/null semantics do not
 * map cleanly to a plain Jac member access. Returns the source or null.
 */
function emitMemberAccess(node, path, diags, ctx = {}) {
  // `map.keys().next().value` is JS iterator protocol. Jac's dict view is an
  // iterable, so preserve the empty-map `undefined` result as None.
  const nextCall = node.object;
  const keysCall = nextCall?.callee?.object;
  if (!node.computed && node.property?.name === "value"
    && nextCall?.type === "CallExpression" && (nextCall.arguments ?? []).length === 0
    && nextCall.callee?.type === "MemberExpression" && !nextCall.callee.computed
    && nextCall.callee.property?.name === "next"
    && keysCall?.type === "CallExpression" && (keysCall.arguments ?? []).length === 0
    && keysCall.callee?.type === "MemberExpression" && !keysCall.callee.computed
    && keysCall.callee.property?.name === "keys"
    && isKnownMapReceiver(keysCall.callee.object, ctx)) {
    const recv = emitExpr(keysCall.callee.object, path, diags, ctx);
    if (recv === null) return null;
    return `next(iter(${recv}.keys()), None)`;
  }
  if (!node.computed
    && node.property?.type === "Identifier"
    && (node.object?.type === "MemberExpression" || node.object?.type === "OptionalMemberExpression")
    && !node.object.computed
    && node.object.property?.type === "Identifier"
    && node.object.property.name === "groups"
    && node.object.object?.type === "Identifier"
    && MATCH_LOCALS.has(identText(node.object.object.name))) {
    const matchName = identText(node.object.object.name);
    return `(${matchName}.groupdict().get('${node.property.name}') as str)`;
  }
  if (node.optional && !ctx.disabledOptional?.has(node)) {
    if (!isStableRepeatableExpr(node.object)) {
      diags.push(diag("E7215", "Optional member receiver must be side-effect-free", path));
      return null;
    }
    const recv = emitExpr(node.object, path, diags, ctx);
    if (recv === null) return null;
    const plain = emitMemberAccess({ ...node, optional: false }, path, diags, ctx);
    if (plain === null) return null;
    return `(${plain} if ${recv} is not None else None)`;
  }
  // V2.12: `process.env.NAME` / `process.env["NAME"]` -> `environ.get("NAME")`
  // via `import from os { environ }` (str | None, matching JS string|undefined).
  if (
    !node.computed
    && node.object?.type === "MetaProperty"
    && node.object.meta?.name === "import"
    && node.object.property?.name === "meta"
    && node.property?.name === "url"
  ) {
    return "__file__";
  }
  if (
    !node.computed
    && node.object?.type === "MemberExpression"
    && !node.object.computed
    && node.object.object?.type === "Identifier"
    && node.object.object.name === "process"
    && node.object.property?.name === "env"
    && node.property?.type === "Identifier"
  ) {
    PROCESS_ENV_INTEROP = true;
    return `environ.get("${node.property.name}")`;
  }
  if (
    node.computed
    && node.object?.type === "MemberExpression"
    && !node.object.computed
    && node.object.object?.type === "Identifier"
    && node.object.object.name === "process"
    && node.object.property?.name === "env"
  ) {
    const key = emitExpr(node.property, path, diags, ctx);
    if (key === null) return null;
    PROCESS_ENV_INTEROP = true;
    return `environ.get(${key})`;
  }
  // `super.m()` — Jac's sanctioned form calls `super()` (parent instance)
  // before attribute access; bare `super.m` type-checks as Unknown (E1032).
  if (!node.computed && node.object?.type === "Super") {
    const sprop = emitExpr(node.property, path, diags, ctx);
    if (sprop === null) return null;
    return `super().${sprop}`;
  }
  if (!node.computed
    && node.object?.type === "Identifier"
    && node.property?.type === "Identifier"
    && ctx.className === node.object.name
    && ctx.staticHoists?.has(node.property.name)) {
    return node.property.name;
  }
  // Jac has no JavaScript property-getter invocation syntax. Lower a getter to
  // a zero-argument ability and make receiver reads within the declaring class
  // explicit calls. This is AST/provenance based, so ordinary fields (including
  // the ubiquitous list/string `.length`) retain their existing lowering.
  if (!node.computed
    && node.object?.type === "ThisExpression"
    && node.property?.type === "Identifier"
    && ctx.getterNames?.has(node.property.name)) {
    return `self.${node.property.name}()`;
  }
  const obj = emitExpr(node.object, path, diags, ctx);
  if (obj === null) return null;
  if (node.computed) {
    // be resolved — the namespace is lowered away, so emitting it would dangle.
    if (node.object?.type === "Identifier" && REACT_NAMESPACE_LOCALS.has(node.object.name)) {
      diags.push(diag("E7214", "Computed member access on a React namespace is not supported", path));
      return null;
    }
    const idx = emitExpr(node.property, path, diags, ctx);
    if (idx === null) return null;
    // V2.12: a subscript on a Match-shape local is a capture-group read in JS
    // (`match[1]`); Python's Match exposes `.group(n)`.
    if (node.object?.type === "Identifier" && MATCH_LOCALS.has(identText(node.object.name))
      && node.property?.type === "Literal" && typeof node.property.value === "number") {
      return `${obj}.group(${node.property.value})`;
    }
    return `${obj}[${idx}]`;
  }
  if (node.property?.type !== "Identifier") {
    diags.push(diag("E7215", "Only simple or computed member access is supported", path));
    return null;
  }
  // JS `.length` on an array/string is Jac `len(...)`. Emitting the raw `.length`
  // attribute fails the type checker (E1030: list/str has no attribute length),
  // sinking the whole file. `length` is never a JS method call, so this read-only
  // rewrite is unambiguous. A user object with a real `.length` field would fail
  // `len()` under check and be pruned downstream — no worse than the status quo.
  if (usesDictBracketAccess(node, ctx)) {
    let fieldType = node.object?.type === "Identifier"
      ? ctx.dictFieldTypes?.get(node.object.name)?.get(node.property.name)
      : null;
    if (!fieldType && node.object?.type === "CallExpression"
      && node.object.callee?.type === "Identifier") {
      fieldType = DICT_RETURN_FIELD_TYPES.get(node.object.callee.name)?.get(node.property.name);
    }
    const access = `${obj}["${node.property.name}"]`;
    return fieldType ? `(${access} as ${fieldType})` : access;
  }
  if (node.property.name === "size" && isKnownMapReceiver(node.object, ctx)) {
    return `len(${obj})`;
  }
  if (node.property.name === "length") {
    return `len(${obj})`;
  }
  return `${obj}.${node.property.name}`;
}

/** Fix 2: lower a FLAT object/array binding pattern to explicit Jac binds.
 * Handles only the simple case — object `{a, b}` / `{a: b}` (rename) and array
 * `[x, y]` (holes allowed) whose leaves are plain identifiers. Nested patterns,
 * defaults (`{a = 1}`), rest (`...rest`), computed/spread keys are rejected
 * (returns null, no diag) so callers keep their existing fail-closed reject and
 * we do not over-widen.
 *   `valExpr` is the already-emitted Jac source for the source value.
 *   `forParam=false` (var-decl): the value is evaluated once into an
 *      `any`-typed temp so member/index access type-checks regardless of the
 *      RHS's concrete type and the RHS is never re-run per bound name.
 *   `forParam=true` (helper param): `valExpr` is a synthetic `any`-typed param
 *      identifier already bound, so no temp is introduced.
 * Returns { lines } (Jac statements) or null. */
function lowerFlatPattern(idNode, valExpr, forParam, ctx, fieldTypes = null) {
  const binds = [];
  if (idNode?.type === "ObjectPattern") {
    for (const pr of idNode.properties ?? []) {
      if (pr?.type !== "Property") return null;          // RestElement / spread
      if (pr.computed) return null;                      // computed key
      if (pr.key?.type !== "Identifier") return null;
      if (pr.value?.type !== "Identifier") return null;  // nested / default / non-ident
      binds.push({ target: pr.value.name, access: `.${pr.key.name}`, type: fieldTypes?.get(pr.key.name) ?? null });
    }
  } else if (idNode?.type === "ArrayPattern") {
    const els = idNode.elements ?? [];
    for (let i = 0; i < els.length; i++) {
      const el = els[i];
      if (el === null || el === undefined) continue;     // hole, e.g. [, b]
      if (el.type !== "Identifier") return null;         // rest / default / nested
      binds.push({ target: el.name, access: `[${i}]`, type: null });
    }
  } else {
    return null;
  }
  if (binds.length === 0) return null;

  const lines = [];
  let base;
  if (forParam) {
    base = valExpr;
  } else {
    const n = (ctx.__patTmp = (ctx.__patTmp ?? -1) + 1);
    base = `_jx_d${n}`;
    lines.push(`${base}: any = ${valExpr};`);
  }
  for (const b of binds) {
    lines.push(b.type
      ? `${b.target}: ${b.type} = (${base}${b.access} as ${b.type});`
      : `${b.target} = ${base}${b.access};`);
  }
  return { lines };
}

/** V2.2 + V2.3: lower a general (non-hook) statement to Jac source lines.
 * Returns an array of strings, each indented relative to the statement's own
 * start (nested block bodies are indented one further level). The caller adds
 * the base indentation for the enclosing context. Returns null (with a diag
 * pushed) for any statement form without an approved mapping. `ctx.inLambda`
 * forbids `return` outside value-bearing contexts is not enforced here — Jac
 * permits return inside lambdas.
 */
function emitStatement(stmt, ctx) {
  const { path, diags } = ctx;
  const kind = stmt?.type ?? "";
  const INDENT = "    ";

  function indentBlock(lines) {
    return lines.map((l) => (l === "" ? "" : INDENT + l));
  }

  if (kind === "EmptyStatement") return [];

  if (kind === "BlockStatement") {
    if (ctx.failOpen) return emitBlockFailOpen(stmt.body ?? [], ctx);
    const out = [];
    for (const s of stmt.body ?? []) {
      const lines = emitStatement(s, ctx);
      if (lines === null) return null;
      out.push(...lines);
    }
    return out;
  }

  if (kind === "VariableDeclaration") {
    if (stmt.kind !== "const" && stmt.kind !== "let") {
      diags.push(diag("E7231", `Unsupported variable kind: ${stmt.kind} (use const or let)`, path));
      return null;
    }
    const out = [];
    for (const d of stmt.declarations ?? []) {
      // Fix 2: lower flat object/array destructuring to explicit binds.
      if (d.id?.type === "ObjectPattern" || d.id?.type === "ArrayPattern") {
        if (d.init === null || d.init === undefined) {
          diags.push(diag("E7231", "Variable declarations must have an initializer", path));
          return null;
        }
        const initVal = emitExpr(d.init, path, diags, ctx);
        if (initVal === null) return null;
        const lowered = lowerFlatPattern(d.id, initVal, false, ctx);
        if (lowered === null) {
          diags.push(diag("E7231", "Destructuring/pattern variable declarations are not supported (bind one identifier per declaration)", path));
          return null;
        }
        out.push(...lowered.lines);
        continue;
      }
      if (d.id?.type !== "Identifier") {
        diags.push(diag("E7231", "Destructuring/pattern variable declarations are not supported (bind one identifier per declaration)", path));
        return null;
      }
      if (d.init === null || d.init === undefined) {
        const ann = d.id.typeAnnotation?.typeAnnotation;
        if (stmt.kind !== "let" || !ann) {
          diags.push(diag("E7231", "Uninitialized variables require an explicit type annotation", path));
          return null;
        }
        const jacType = tsTypeToJac(ann, path, diags);
        if (!jacType) return null;
        out.push(`${identText(d.id.name)}: ${jacType};`);
        continue;
      }
      const val = emitExpr(d.init, path, diags, ctx);
      if (val === null) return null;
      noteDictBinding(d.id.name, d.init, d.id.typeAnnotation?.typeAnnotation, ctx);
      // Preserve a TS type annotation when present (lossless; keeps JS `number`
      // mapped to Jac `float` rather than letting `0` infer to `int`).
      const ann = d.id.typeAnnotation?.typeAnnotation;
      const name = identText(d.id.name);
      let prefix = `${name} = `;
      if (ann) {
        const jacType = tsTypeToJac(ann, path, diags);
        if (!jacType) return null;
        prefix = `${name}: ${jacType} = `;
      } else if (ctx.floatLocals?.has(d.id.name)) {
        prefix = `${name}: float = `;
      } else {
        const inferred = inferExprType(unwrapTsValue(d.init), path, []);
        // Jac otherwise preserves literal-string/bool types for mutable `let`
        // locals, rejecting later updates with ordinary str/bool values.
        if (inferred === "str" || inferred === "bool") prefix = `${name}: ${inferred} = `;
      }
      const initValue = !ann && ctx.floatLocals?.has(d.id.name) ? `float(${val})` : val;
      out.push(`${prefix}${initValue};`);
    }
    return out;
  }

  if (kind === "ExpressionStatement") {
    const expr = stmt.expression;
    // Discard-result Map mutations can lower to dict mutations without having
    // to emulate JS's expression return values (`set` returns the Map; `delete`
    // returns a bool). Provenance-gated to bindings initialized by `new Map`.
    if (expr?.type === "CallExpression" && !expr.optional
      && expr.callee?.type === "MemberExpression" && !expr.callee.computed
      && isKnownMapReceiver(expr.callee.object, ctx)) {
      const method = expr.callee.property?.name;
      const recv = emitExpr(expr.callee.object, path, diags, ctx);
      if (recv === null) return null;
      if (method === "set" && (expr.arguments ?? []).length === 2) {
        const key = emitExpr(expr.arguments[0], path, diags, ctx);
        const value = emitExpr(expr.arguments[1], path, diags, ctx);
        if (key === null || value === null) return null;
        return [`${recv}[${key}] = ${value};`];
      }
      if (method === "delete" && (expr.arguments ?? []).length === 1) {
        const key = emitExpr(expr.arguments[0], path, diags, ctx);
        if (key === null) return null;
        return [`${recv}.pop(${key}, None);`];
      }
    }
    // V2.13: discard-result splice lowers to slice mutation. This mapping is
    // confined to statement position because JS returns the removed slice.
    if (
      expr?.type === "CallExpression" && !expr.optional
      && expr.callee?.type === "MemberExpression" && !expr.callee.computed
      && expr.callee.property?.name === "splice"
      && ((expr.arguments ?? []).length === 2 || (expr.arguments ?? []).length === 3)
    ) {
      const recv = emitExpr(expr.callee.object, path, diags, ctx);
      const start = emitExpr(expr.arguments[0], path, diags, ctx);
      const count = emitExpr(expr.arguments[1], path, diags, ctx);
      if (recv === null || start === null || count === null) return null;
      if ((expr.arguments ?? []).length === 3) {
        const value = emitExpr(expr.arguments[2], path, diags, ctx);
        if (value === null) return null;
        return [`${recv}[${start}:(${start}) + (${count})] = [${value}];`];
      }
      return count === "1" ? [`del ${recv}[${start}];`]
        : [`del ${recv}[${start}:(${start}) + (${count})];`];
    }
    if (expr?.type === "UpdateExpression") {
      const arg = emitExpr(expr.argument, path, diags, ctx);
      if (arg === null) return null;
      const delta = expr.operator === "++" ? "1" : "-1";
      return [`${arg} += ${delta};`];
    }
    // Compound assignment (+=, -=, ...) -> Jac compound forms where supported.
    if (expr?.type === "AssignmentExpression") {
      const left = emitExpr(expr.left, path, diags, ctx);
      if (left === null) return null;
      let right = emitExpr(expr.right, path, diags, ctx);
      if (right === null) return null;
      const op = COMPOUND_ASSIGN_OPS[expr.operator];
      if (op === undefined) {
        diags.push(diag("E7215", `Unsupported assignment operator: ${expr.operator}`, path));
        return null;
      }
      if (expr.left?.type === "Identifier" && ctx.floatLocals?.has(expr.left.name)
        && ["+=", "-=", "*=", "/=", "%=", "**="].includes(expr.operator)) {
        return [`${left} = float(${left} ${expr.operator.slice(0, -1)} ${right});`];
      }
      // Record fields named `length` originate as TS number/float, but in the
      // index-advance idiom they are integral counts. Keep an int loop cursor
      // integral rather than widening every index because of the record cast.
      if (expr.left?.type === "Identifier" && !ctx.floatLocals?.has(expr.left.name)
        && expr.operator === "+="
        && (expr.right?.type === "MemberExpression" || expr.right?.type === "OptionalMemberExpression")
        && !expr.right.computed && expr.right.property?.name === "length") {
        right = `int(${right})`;
      }
      return [`${left} ${op} ${right};`];
    }
    const text = emitExpr(expr, path, diags, ctx);
    if (text === null) return null;
    return [`${text};`];
  }

  if (kind === "ReturnStatement") {
    if (ctx.allowReturn === false) {
      diags.push(diag("E7214", "return inside component control flow is not supported (components use a single JSX return)", path));
      return null;
    }
    if (stmt.argument === null || stmt.argument === undefined) return ["return;"];
    const val = emitExpr(stmt.argument, path, diags, ctx);
    if (val === null) return null;
    // V2.12: returning an untyped local (assigned from interop/Unknown calls)
    // against a concrete declared return type draws E1002; cast at the sink.
    if (
      ctx.retTypeCast && stmt.argument.type === "Identifier"
      && (ctx.untypedLocals?.has(stmt.argument.name))
    ) {
      return [`return (${val} as ${ctx.retTypeCast});`];
    }
    return [`return ${val};`];
  }

  if (kind === "IfStatement") {
    return emitIfChain(stmt, ctx, INDENT);
  }

  if (kind === "ForOfStatement") {
    if (stmt.await) {
      diags.push(diag("E7230", "for-await-of loops are not supported", path));
      return null;
    }
    const binding = forLoopBinding(stmt.left, stmt.right, path, diags, ctx);
    if (binding === null) return null;
    const right = emitExpr(stmt.right, path, diags, ctx);
    if (right === null) return null;
    const bodyCtx = {
      ...ctx,
      dictBindings: new Set(ctx.dictBindings ?? []),
      dictFieldTypes: new Map(ctx.dictFieldTypes ?? []),
    };
    if (stmt.right?.type === "Identifier" && ctx.dictListBindings?.has(stmt.right.name)) {
      bodyCtx.dictBindings.add(binding.loopVar);
      const fieldTypes = ctx.dictListFieldTypes?.get(stmt.right.name);
      if (fieldTypes) bodyCtx.dictFieldTypes.set(binding.loopVar, fieldTypes);
    }
    const bodyLines = emitStatement(stmt.body, bodyCtx);
    if (bodyLines === null) return null;
    return [
      `for ${identText(binding.loopVar)} in ${right} {`,
      ...indentBlock([...binding.preamble, ...bodyLines]),
      "}",
    ];
  }

  if (kind === "ForInStatement") {
    // JS for..in enumerates string keys with prototype-chain semantics that do
    // not match Jac iteration; defer rather than silently rewrite.
    diags.push(diag("E7230", "for...in loops are not supported (use for...of over the iterable)", path));
    return null;
  }

  if (kind === "ForStatement") {
    const cFor = tryEmitCStyleFor(stmt, ctx);
    if (cFor !== null) return cFor;
    diags.push(diag("E7230", "C-style for loops are not supported (rewrite as while or for...of)", path));
    return null;
  }

  if (kind === "WhileStatement") {
    const test = emitExpr(stmt.test, path, diags, ctx);
    if (test === null) return null;
    const bodyLines = emitStatement(stmt.body, ctx);
    if (bodyLines === null) return null;
    return [`while ${test} {`, ...indentBlock(bodyLines), "}"];
  }

  if (kind === "DoWhileStatement") {
    diags.push(diag("E7230", "do...while loops are not supported (rewrite as while)", path));
    return null;
  }

  if (kind === "BreakStatement") {
    if (stmt.label) {
      diags.push(diag("E7230", "Labeled break is not supported", path));
      return null;
    }
    return ["break;"];
  }
  if (kind === "ContinueStatement") {
    if (stmt.label) {
      diags.push(diag("E7230", "Labeled continue is not supported", path));
      return null;
    }
    return ["continue;"];
  }

  if (kind === "SwitchStatement") {
    // V2.12: `switch (d) { case a: ...; break; ... default: ... }` -> an
    // if/elif/else chain over a scrutinee temp. Sound only without fallthrough:
    // every case body must end in break/return/continue/throw (or be the final
    // case). Consecutive empty-body cases group into one multi-test branch.
    const disc = emitExpr(stmt.discriminant, path, diags, ctx);
    if (disc === null) return null;
    const groups = [];
    let defaultGroup = null;
    for (const c of stmt.cases ?? []) {
      if (c.test === null || c.test === undefined) {
        if (defaultGroup) {
          diags.push(diag("E7230", "Multiple switch defaults are not supported", path));
          return null;
        }
        defaultGroup = { body: c.consequent ?? [] };
        continue;
      }
      if ((c.consequent ?? []).length === 0 && groups.length
        && !groups[groups.length - 1].sealed) {
        groups[groups.length - 1].tests.push(c.test);
        continue;
      }
      groups.push({ tests: [c.test], body: c.consequent ?? [], sealed: false });
    }
    const endsWithJump = (body) => {
      const last = body[body.length - 1];
      if (!last) return false;
      if (last.type === "BreakStatement" || last.type === "ContinueStatement"
        || last.type === "ReturnStatement" || last.type === "ThrowStatement") return true;
      if (last.type === "BlockStatement") return endsWithJump(last.body ?? []);
      return false;
    };
    const allGroups = [...groups];
    if (defaultGroup) allGroups.push({ tests: null, body: defaultGroup.body });
    for (let i = 0; i < allGroups.length; i += 1) {
      const g = allGroups[i];
      const isLast = i === allGroups.length - 1;
      if (!isLast && !endsWithJump(g.body)) {
        diags.push(diag("E7230", "Switch fallthrough is not supported (add break/return to each case)", path));
        return null;
      }
    }
    const out = [`_sw = ${disc};`];
    for (let i = 0; i < allGroups.length; i += 1) {
      const g = allGroups[i];
      const bodyLines = [];
      for (const s of g.body) {
        if (s.type === "BreakStatement") continue;
        const lines = emitStatement(s, ctx);
        if (lines === null) return null;
        bodyLines.push(...lines);
      }
      const kw = i === 0 ? "if" : "elif";
      if (g.tests === null) {
        out.push(`else {`, ...indentBlock(bodyLines), `}`);
      } else {
        const conds = [];
        for (const t of g.tests) {
          const tt = emitExpr(t, path, diags, ctx);
          if (tt === null) return null;
          conds.push(`(_sw == ${tt})`);
        }
        out.push(`${kw} ${conds.join(" or ")} {`, ...indentBlock(bodyLines), `}`);
      }
    }
    return out;
  }

  if (kind === "TryStatement") {
    const tryLines = emitStatement(stmt.block, ctx);
    if (tryLines === null) return null;
    const out = ["try {", ...indentBlock(tryLines), "}"];
    if (stmt.handler) {
      const param = stmt.handler.param;
      if (param && param.type !== "Identifier") {
        diags.push(diag("E7230", "Catch bindings must use a simple identifier", path));
        return null;
      }
      const catchLines = emitStatement(stmt.handler.body, ctx);
      if (catchLines === null) return null;
      const binding = param ? ` as ${identText(param.name)}` : "";
      out.push(`except Exception${binding} {`, ...indentBlock(catchLines), "}");
    }
    if (stmt.finalizer) {
      const finallyLines = emitStatement(stmt.finalizer, ctx);
      if (finallyLines === null) return null;
      out.push("finally {", ...indentBlock(finallyLines), "}");
    }
    return out;
  }

  if (kind === "ThrowStatement"
      || kind === "LabeledStatement" || kind === "DebuggerStatement") {
    diags.push(diag("E7230", `${kind} is not supported in V2 (deferred to a later slice)`, path));
    return null;
  }

  diags.push(diag("E7214", `Unsupported statement: ${kind}`, path));
  return null;
}

// Statement-level fail-open (opt-in via ctx.failOpen; helpers only). Emit each
// statement in a block; on an unsupported one, drop just that statement and keep
// the rest instead of sinking the whole declaration. Soundness:
//   - A kept statement referencing a dropped binding is dropped transitively
//     (fixpoint over the block), so no emitted Jac dangles.
//   - Dropping a statement that carries a `return` would leave a typed function
//     without a return on that path, so we bail (null) and let the caller fall
//     back to the coarser decl-level drop.
//   - If nothing meaningful survives, bail too (an empty husk is worse than a
//     recorded decl-level skip).
// Every drop is recorded in ctx.droppedStatements so the envelope can tally it.
function emitBlockFailOpen(stmts, ctx) {
  const entries = [];
  for (const s of stmts) {
    const trial = { ...ctx, diags: [] };
    let lines = null;
    try { lines = emitStatement(s, trial); } catch { lines = null; }
    const bound = boundSiblingNames(s);
    if (lines === null) {
      if (containsReturn(s)) return null;
      entries.push({ stmt: s, lines: null, bound, refs: new Set(), dropped: true,
        code: trial.diags[0]?.code ?? "E7214", msg: trial.diags[0]?.message ?? "" });
    } else {
      const refs = new Set();
      collectReferencedNames(s, refs);
      entries.push({ stmt: s, lines, bound, refs, dropped: false });
    }
  }
  const droppedNames = new Set();
  for (const e of entries) if (e.dropped) for (const n of e.bound) droppedNames.add(n);
  let changed = true;
  while (changed) {
    changed = false;
    for (const e of entries) {
      if (e.dropped) continue;
      for (const r of e.refs) {
        if (droppedNames.has(r) && !e.bound.includes(r)) {
          if (containsReturn(e.stmt)) return null;
          e.dropped = true;
          e.code = "transitive-stmt";
          e.msg = `references dropped binding '${r}'`;
          for (const n of e.bound) if (!droppedNames.has(n)) droppedNames.add(n);
          changed = true;
          break;
        }
      }
    }
  }
  const out = [];
  let keptReal = 0;
  let droppedAny = false;
  for (const e of entries) {
    if (e.dropped) {
      droppedAny = true;
      ctx.droppedStatements.push({ code: e.code ?? "E7214", msg: e.msg ?? "", kind: e.stmt.type });
      // Leave the original JS in place as a hole comment for the LLM pass. It
      // binds nothing, so transitive-drop of dependents is unaffected — the hole
      // is pure context, and the file's soundness is unchanged (comments never
      // parse-break). counts as neither kept nor a husk (keptReal untouched).
      if (HOLE_CTX.emitHoles) out.push(...holeCommentLines(e.stmt, e.code ?? "E7214", e.msg ?? ""));
      continue;
    }
    out.push(...e.lines);
    if (e.stmt.type !== "EmptyStatement") keptReal += 1;
  }
  // Bail only when statements were dropped AND nothing meaningful survived: an
  // emptied husk of real logic is misleading training data, so fall back to a
  // decl-level drop. A body that was genuinely empty (or all-EmptyStatement) to
  // begin with is valid Jac and emitted as-is — matching strict-mode output.
  if (droppedAny && !keptReal) return null;
  return out;
}

const COMPOUND_ASSIGN_OPS = {
  "=": "=",
  "+=": "+=", "-=": "-=", "*=": "*=", "/=": "/=", "%=": "%=", "**=": "**=",
};

/** Flatten an if / else-if / else chain into Jac `if ... { } elif ... { } else { }`. */
function emitIfChain(stmt, ctx, INDENT) {
  const { path, diags } = ctx;
  const out = [];
  let cur = stmt;
  let first = true;
  while (cur?.type === "IfStatement") {
    const test = emitExpr(cur.test, path, diags, ctx);
    if (test === null) return null;
    const consLines = emitStatement(cur.consequent, ctx);
    if (consLines === null) return null;
    const kw = first ? "if" : "elif";
    out.push(`${kw} ${test} {`);
    for (const l of consLines) out.push(l === "" ? "" : INDENT + l);
    out.push("}");
    first = false;
    const alt = cur.alternate;
    if (alt === null || alt === undefined) {
      cur = null;
      break;
    }
    if (alt.type === "IfStatement") {
      cur = alt;
      continue;
    }
    // Non-if alternate: a final else block.
    const elseLines = emitStatement(alt, ctx);
    if (elseLines === null) return null;
    out.push("else {");
    for (const l of elseLines) out.push(l === "" ? "" : INDENT + l);
    out.push("}");
    cur = null;
    break;
  }
  return out;
}

/** Resolve/lower a for-loop binding. Flat destructuring binds through a stable
 * synthetic iteration variable before the original loop body. */
function forLoopBinding(left, right, path, diags, ctx) {
  if (left?.type === "Identifier") return { loopVar: left.name, preamble: [] };
  if (left?.type === "VariableDeclaration") {
    if ((left.declarations ?? []).length !== 1) {
      diags.push(diag("E7230", "for...of must bind a single variable", path));
      return null;
    }
    const id = left.declarations[0].id;
    if (id?.type === "Identifier") return { loopVar: id.name, preamble: [] };
    if (id?.type === "ArrayPattern" || id?.type === "ObjectPattern") {
      const index = (ctx.__forTmp = (ctx.__forTmp ?? -1) + 1);
      const loopVar = `_jx_item${index}`;
      // Intl.Segmenter iteration exposes `{ segment: string, ... }`. Preserve
      // the one field Pi consumes so downstream string operations type-check.
      const segmentFields = right?.type === "CallExpression"
        && right.callee?.type === "MemberExpression" && !right.callee.computed
        && right.callee.property?.name === "segment"
        ? new Map([["segment", "str"]])
        : null;
      const lowered = lowerFlatPattern(id, loopVar, true, ctx, segmentFields);
      if (lowered !== null) return { loopVar, preamble: lowered.lines };
    }
    diags.push(diag("E7230", "for...of destructuring must use a flat array/object pattern", path));
    return null;
  }
  diags.push(diag("E7230", `Unsupported for...of left-hand side: ${left?.type}`, path));
  return null;
}

// V2.12: Python interop state for JS regex lowering. Reset per file in
// convertEnvelope; read at import-assembly time to emit `import from re`.
let REGEX_INTEROP = { compile: false, search: false, split: false, sub: false, flags: new Set() };
// V2.12: `process.env` -> `os.environ` interop flag (import emission).
let PROCESS_ENV_INTEROP = false;
const KNOWN_AMBIENT_JS_NAMESPACES = new Set(["Intl"]);
let AMBIENT_INTEROP_GLOBALS = new Set();
// V2.12: per-file identifier renames — a JS local/param bound to a Jac
// statement keyword (`match`, `entry`, ...) cannot appear bare in Jac source
// (parser error). File-wide rename `<name>` -> `<name>_j` is applied at both
// binding and reference sites; member properties are exempt (they never pass
// through the Identifier emit path).
let IDENT_RENAMES = new Map();
// V2.12: locals bound to `x.match(/re/)` — Python Match access is `.group(n)`,
// so computed subscripts on these names lower to `.group(n)` (final names,
// post-rename).
let MATCH_LOCALS = new Set();
// V2.12: functions (or methods) whose TS return annotation is an object
// literal type — calls to them produce dict values, so member access on their
// results lowers to subscripts. Collected per file in convertEnvelope.
let DICT_RETURNING_FUNCS = new Set();
let DICT_RETURN_FIELD_TYPES = new Map();
// Bindings whose value originates at `new Map(...)`. Map lowers to Jac's dict,
// but its JS-only API is rewritten only when AST provenance proves the receiver.
let MODULE_MAP_BINDINGS = new Set();
// Locally declared helpers with a TypeScript `number` return. Used by numeric
// flow so aliases of helper results remain float through compound updates.
let NUMBER_RETURNING_FUNCS = new Set();
let SOURCE_BOUND_NAMES = new Set();
let EXPR_TEMP_INDEX = 0;
// V2.12: locally-declared class names — `new LocalClass(...)` lowers to the
// Jac call construction `LocalClass(...)`.
let LOCAL_CLASSES = new Set();
// V2.12: module-level names bound to regex literals — `.test(x)` on these
// lowers to `search(<compiled>, x)` (re functions accept compiled patterns).
let REGEX_CONSTS = new Set();
const JAC_RESERVED_LOCALS = new Set([
  "match", "with", "entry", "has", "glob", "del", "edge", "node", "graph",
  "walker", "spawn", "visit", "report", "disengage", "skip", "take",
  "ignore", "ability", "import", "await", "defer",
  // Python/Jac builtins a JS local can shadow — a shadowed builtin breaks the
  // lowered call sites (e.g. a `max` param makes `max(...)` resolve to it).
  "min", "max", "len", "abs", "all", "any", "round", "sum", "sorted",
  "next", "ord", "chr", "print", "type", "id", "hash", "iter",
  "range", "filter", "map", "int", "float", "str", "bool", "list",
  "dict", "set", "tuple", "compile", "search", "sub",
]);

/** Apply the per-file reserved-name rename to a binding/reference identifier. */
function identText(name) {
  return IDENT_RENAMES.get(name) ?? name;
}

function freshExprTemp(prefix) {
  let name;
  do {
    name = `_jx_${prefix}${EXPR_TEMP_INDEX++}`;
  } while (SOURCE_BOUND_NAMES.has(name));
  SOURCE_BOUND_NAMES.add(name);
  return name;
}

/** Pre-pass: collect local/param bindings that collide with Jac statement
 * keywords, and locals initialized from `.match(/re/)` (Match-shape locals). */
function collectLocalRenames(body) {
  const renames = new Map();
  const matchLocals = new Set();
  const seen = new Set();
  const walk = (n) => {
    if (!n || typeof n !== "object") return;
    if (Array.isArray(n)) { for (const x of n) walk(x); return; }
    const bind = (id) => {
      if (id?.type === "Identifier" && JAC_RESERVED_LOCALS.has(id.name) && !seen.has(id.name)) {
        seen.add(id.name);
        renames.set(id.name, `${id.name}_j`);
      }
    };
    if (n.type === "VariableDeclarator") {
      bind(n.id);
      if (
        n.id?.type === "Identifier"
        && n.init?.type === "CallExpression"
        && n.init.callee?.type === "MemberExpression"
        && !n.init.callee.computed
        && n.init.callee.property?.name === "match"
        && (
          (n.init.arguments?.[0]?.type === "Literal" && n.init.arguments[0].regex)
          || (n.init.arguments?.[0]?.type === "Identifier" && REGEX_CONSTS.has(n.init.arguments[0].name))
        )
      ) {
        matchLocals.add(n.id.name);
      }
    } else if (n.type === "FunctionDeclaration" || n.type === "FunctionExpression" || n.type === "ArrowFunctionExpression") {
      if (n.type === "FunctionDeclaration") bind(n.id);
      for (const p of n.params ?? []) {
        if (p?.type === "Identifier") bind(p);
        else if (p?.type === "AssignmentPattern") bind(p.left);
      }
    } else if (n.type === "CatchClause") {
      bind(n.param);
    }
    for (const k of Object.keys(n)) {
      if (k === "type" || k === "loc" || k === "range" || k === "start" || k === "end"
        || k.endsWith("Comments")) continue;
      const v = n[k];
      if (v && typeof v === "object") walk(v);
    }
  };
  walk(body);
  const finalMatchLocals = new Set([...matchLocals].map((m) => renames.get(m) ?? m));
  return { renames, matchLocals: finalMatchLocals };
}

/** JS numeric-builtin call table -> Python. Values are arg-index templates;
 * `null` marks impure/unmodeled members (fail closed upstream). */
const JS_MATH_CALLS = {
  max: (args) => `max(${args.map((arg) => `float(${arg})`).join(", ")})`,
  min: (args) => `min(${args.map((arg) => `float(${arg})`).join(", ")})`,
  abs: (args) => `abs(${args.join(", ")})`,
  round: (args) => `round(${args[0]} as float)`,
  floor: (args) => `int((${args[0]}) // 1)`,
  ceil: (args) => `int(-((-${args[0]}) // 1))`,
  pow: (args) => `((${args[0]}) ** (${args[1]}))`,
};

/** Python raw string literal for a regex pattern (quote-char aware). */
function pyRawString(s) {
  const normalized = s
    .replace(/\(\?<([A-Za-z_][A-Za-z0-9_]*)>/g, "(?P<$1>")
    .replace(/\\k<([A-Za-z_][A-Za-z0-9_]*)>/g, "(?P=$1)");
  if (!normalized.includes('"')) return `r"${normalized}"`;
  if (!normalized.includes("'")) return `r'${normalized}'`;
  return `r"""${normalized}"""`;
}

/** JS flag set -> imported Python flag idents (`I`/`M`/`S`), or "". Each use
 * registers the ident in REGEX_INTEROP.flags for the `import from re` line.
 * A cast (`I as int`) is required: the stub flags resolve as Unknown. */
function pyRegexFlagsArg(flags) {
  const f = flags ?? "";
  const parts = [];
  if (f.includes("i")) { parts.push("I as int"); REGEX_INTEROP.flags.add("I"); }
  if (f.includes("m")) { parts.push("M as int"); REGEX_INTEROP.flags.add("M"); }
  if (f.includes("s")) { parts.push("S as int"); REGEX_INTEROP.flags.add("S"); }
  // JS `g` is iteration state (lastIndex), not matching flags — not modeled.
  return parts.length ? `, ${parts.join(" | ")}` : "";
}

function findOptionalBoundary(node, disabled) {
  const current = node?.type === "ChainExpression" ? node.expression : node;
  if (!current) return null;
  if (current.type === "MemberExpression" || current.type === "OptionalMemberExpression") {
    const inner = findOptionalBoundary(current.object, disabled);
    if (inner) return inner;
    return current.optional && !disabled?.has(current) ? current : null;
  }
  if (current.type === "CallExpression" || current.type === "OptionalCallExpression") {
    const inner = findOptionalBoundary(current.callee, disabled);
    if (inner) return inner;
    return current.optional && !disabled?.has(current) ? current : null;
  }
  return null;
}

/** Lower a whole optional chain around one-shot lambda parameters. Walking only
 * the chain spine preserves lazy computed keys/arguments and the full suffix. */
function emitOptionalChainRoot(root, path, diags, ctx = {}) {
  // A JS named-capture read (`match.groups?.name`) maps to Python's
  // `Match.groupdict()`.  Guard the Match itself, not the nonexistent Python
  // `.groups` attribute.  Keeping the call in the conditional's true branch
  // also lets Jac narrow `Match | None` before checking `groupdict()`.
  const current = root?.type === "ChainExpression" ? root.expression : root;
  if ((current?.type === "MemberExpression" || current?.type === "OptionalMemberExpression")
    && current.optional && !current.computed
    && current.property?.type === "Identifier"
    && (current.object?.type === "MemberExpression" || current.object?.type === "OptionalMemberExpression")
    && !current.object.computed && current.object.property?.name === "groups"
    && current.object.object?.type === "Identifier"
    && MATCH_LOCALS.has(identText(current.object.object.name))) {
    const matchName = identText(current.object.object.name);
    return `((${matchName}.groupdict().get('${current.property.name}') as str) if ${matchName} else None)`;
  }
  const boundary = findOptionalBoundary(root, ctx.disabledOptional);
  if (!boundary) return emitExpr(root, path, diags, ctx);
  const isCall = boundary.type === "CallExpression" || boundary.type === "OptionalCallExpression";
  const guardedNode = isCall ? boundary.callee : boundary.object;
  const guarded = emitExpr(guardedNode, path, diags, ctx);
  if (guarded === null) return null;
  const temp = freshExprTemp("opt");
  const exprOverrides = new Map(ctx.exprOverrides ?? []);
  exprOverrides.set(guardedNode, temp);
  const disabledOptional = new Set(ctx.disabledOptional ?? []);
  disabledOptional.add(boundary);
  const body = emitOptionalChainRoot(root, path, diags, {
    ...ctx,
    exprOverrides,
    disabledOptional,
  });
  if (body === null) return null;
  return `((lambda (${temp}: any) -> any { return (${body} if ${temp} is not None else None); })(${guarded}))`;
}

function emitNullishOnce(node, path, diags, ctx) {
  const left = emitExpr(node.left, path, diags, ctx);
  if (left === null) return null;
  const right = emitExpr(node.right, path, diags, ctx);
  if (right === null) return null;
  const temp = freshExprTemp("null");
  return `((lambda (${temp}: any) -> any { return (${temp} if ${temp} is not None else ${right}); })(${left}))`;
}

function emitExpr(node, path, diags, ctx = {}) {
  if (ctx.exprOverrides?.has(node)) return ctx.exprOverrides.get(node);
  const kind = node?.type ?? "";
  if (kind === "Literal") {
    const v = node.value;
    // V2.12: JS regex literal -> Python `re.compile(...)` (module interop).
    // JS/Python regex dialects differ on edge cases; mapping note records it.
    if (node.regex) {
      REGEX_INTEROP.compile = true;
      return `compile(${pyRawString(node.regex.pattern ?? "")}${pyRegexFlagsArg(node.regex.flags)})`;
    }
    if (typeof v === "string") return `"${escapeJsxString(v)}"`;
    if (typeof v === "number") return String(v);
    if (typeof v === "boolean") return v ? "True" : "False";
    if (v === null) return "None";
    // RegExp / BigInt literals: reject (deferred to a dedicated slice).
    diags.push(diag("E7215", `Unsupported literal value: ${JSON.stringify(v)}`, path));
    return null;
  }
  if (kind === "StringLiteral") return `"${escapeJsxString(node.value)}"`;
  if (kind === "NumericLiteral") return String(node.value);
  if (kind === "BooleanLiteral") return node.value ? "True" : "False";
  if (kind === "NullLiteral") return "None";
  if (kind === "Identifier") {
    // JS `undefined` has no Jac binding; merge into None (nullish semantics
    // coincide for the `x ?? y` / `x ? y : undefined` shapes we lower).
    if (node.name === "undefined") return "None";
    return identText(node.name);
  }
  if (kind === "ParenthesizedExpression") return emitExpr(node.expression, path, diags, ctx);
  // Fix 5: TS value-position wrappers carry no runtime meaning; strip them so a
  // nested `x as T` / `x!` / `<T>x` inside an otherwise-pure init (e.g. a config
  // object's `[[..]] as [LngLatLike, LngLatLike]`) emits its inner value instead
  // of sinking the whole declaration. `unwrapTsValue` already strips the *top*
  // wrapper; this handles arbitrarily nested ones.
  if (kind === "TSNonNullExpression") {
    const inner = emitExpr(node.expression, path, diags, ctx);
    if (inner === null) return null;
    // Jac does not carry TypeScript's postfix non-null assertion. Casting the
    // already-evaluated value to `any` removes None from checker-visible access
    // while retaining the same runtime failure behavior if the assertion lied.
    return `(${inner} as any)`;
  }
  if (kind === "TSAsExpression" || kind === "TSSatisfiesExpression"
    || kind === "TSTypeAssertion") {
    return emitExpr(node.expression, path, diags, ctx);
  }
  if (kind === "MemberExpression") return emitMemberAccess(node, path, diags, ctx);
  if (kind === "MetaProperty" && node.meta?.name === "import" && node.property?.name === "meta") {
    return "__file__";
  }
  if (kind === "OptionalMemberExpression") {
    if (ctx.disabledOptional?.has(node)) {
      return emitMemberAccess({ ...node, type: "MemberExpression", optional: false }, path, diags, ctx);
    }
    return emitOptionalChainRoot(node, path, diags, ctx);
  }
  if (kind === "OptionalCallExpression" || (kind === "CallExpression" && node.optional)) {
    if (ctx.disabledOptional?.has(node)) {
      return emitExpr({ ...node, type: "CallExpression", optional: false }, path, diags, ctx);
    }
    return emitOptionalChainRoot(node, path, diags, ctx);
  }
  if (kind === "ChainExpression") {
    return emitOptionalChainRoot(node.expression, path, diags, ctx);
  }
  if (kind === "CallExpression" || kind === "NewExpression") {
    if (node.optional) {
      diags.push(diag("E7215", "Optional call expressions are not supported", path));
      return null;
    }
    // V2.16: collection constructors map to their Jac/Python equivalents.
    if (kind === "NewExpression") {
      const ctor = node.callee?.type === "Identifier" ? node.callee.name : null;
      if (ctor === "Map" && (node.arguments ?? []).length <= 1) {
        if ((node.arguments ?? []).length === 0) return "{}";
        const arg = emitExpr(node.arguments[0], path, diags, ctx);
        if (arg === null) return null;
        return `dict(${arg})`;
      }
      if (ctor === "Set" && (node.arguments ?? []).length <= 1) {
        if ((node.arguments ?? []).length === 0) return "set()";
        const arg = emitExpr(node.arguments[0], path, diags, ctx);
        if (arg === null) return null;
        return `set(${arg})`;
      }
      // `new LocalClass(args)` -> Jac call construction `LocalClass(args)`.
      // Only for classes declared in this file — external `new X()` stays
      // fail-closed (Unknown-call sinks the checker).
      if (ctor && LOCAL_CLASSES.has(ctor)) {
        const args = [];
        for (const arg of node.arguments ?? []) {
          const text = emitExpr(arg, path, diags, ctx);
          if (text === null) return null;
          args.push(text);
        }
        return `${ctor}(${args.join(", ")})`;
      }
      // Imported/server constructor boundary (`new Marked()`, `new
      // StdinBuffer(...)`) -> Jac call construction. Qualified constructors
      // remain fail-closed until their namespace interop is modeled.
      if (ctor) {
        const args = [];
        for (const arg of node.arguments ?? []) {
          if (arg.type === "SpreadElement") return null;
          const text = emitExpr(arg, path, diags, ctx);
          if (text === null) return null;
          args.push(text);
        }
        return `${ctor}(${args.join(", ")})`;
      }
      if (node.callee?.type === "MemberExpression"
        && !node.callee.optional && isStableRepeatableExpr(node.callee)) {
        let root = node.callee.object;
        while (root?.type === "MemberExpression") root = root.object;
        if (root?.type === "Identifier" && KNOWN_AMBIENT_JS_NAMESPACES.has(root.name)) {
          AMBIENT_INTEROP_GLOBALS.add(root.name);
        }
        const callee = emitExpr(node.callee, path, diags, ctx);
        if (callee === null) return null;
        const args = [];
        for (const arg of node.arguments ?? []) {
          if (arg.type === "SpreadElement") {
            diags.push(diag("E7215", "Spread arguments in qualified constructors are not supported", path));
            return null;
          }
          const text = emitExpr(arg, path, diags, ctx);
          if (text === null) return null;
          args.push(text);
        }
        return `${callee}(${args.join(", ")})`;
      }
    }
    if (kind === "NewExpression") {
      diags.push(diag("E7215", "`new` expressions are not supported (preserve as a plain call or interop)", path));
      return null;
    }
    const nativeCall = tryEmitJacNativeCall(node, path, diags, ctx);
    if (nativeCall !== undefined) return nativeCall;
    // V2.12: `subject.match(/pat/)` (no `g` flag) ≡ Python `search(pat, subject)`
    // returning Match | None. Accepts a literal regex or a module regex-const
    // name as the pattern. The `g`-flagged form returns all matches — not
    // modeled.
    {
      const a0 = node.arguments?.[0];
      const litMatch = a0?.type === "Literal" && a0.regex && !a0.regex.flags?.includes("g");
      const constMatch = a0?.type === "Identifier" && REGEX_CONSTS.has(a0.name);
      if (
        node.callee?.type === "MemberExpression"
        && !node.callee.computed
        && node.callee.property?.name === "match"
        && (node.arguments ?? []).length === 1
        && (litMatch || constMatch)
      ) {
        const subject = emitExpr(node.callee.object, path, diags, ctx);
        if (subject === null) return null;
        let patText;
        let flagArg = "";
        if (litMatch) {
          patText = pyRawString(a0.regex.pattern ?? "");
          flagArg = pyRegexFlagsArg(a0.regex.flags);
        } else {
          patText = a0.name;
        }
        REGEX_INTEROP.search = true;
        return `search(${patText}, ${subject}${flagArg})`;
      }
    }
    // V2.12: `Math.*(...)` -> Python numeric builtins. JS trunc-toward-zero vs
    // Python floor division differ on negatives; mapping note records it.
    if (
      node.callee?.type === "MemberExpression"
      && !node.callee.computed
      && node.callee.object?.type === "Identifier"
      && node.callee.object.name === "Math"
      && node.callee.property?.type === "Identifier"
    ) {
      const fn = JS_MATH_CALLS[node.callee.property.name];
      if (fn) {
        if ((node.callee.property.name === "max" || node.callee.property.name === "min")
          && (node.arguments ?? []).length === 0) {
          diags.push(diag("E7215", `Math.${node.callee.property.name}() with no arguments is not supported`, path));
          return null;
        }
        const args = [];
        for (const arg of node.arguments ?? []) {
          if (arg.type === "SpreadElement") {
            const text = emitExpr(arg.argument, path, diags, ctx);
            if (text === null) return null;
            if (node.callee.property.name === "max" || node.callee.property.name === "min") {
              args.push(`*[float(_jx_math) for _jx_math in ${text}]`);
            } else {
              args.push(`*${text}`);
            }
            continue;
          }
          const text = emitExpr(arg, path, diags, ctx);
          if (text === null) return null;
          args.push(text);
        }
        if (args.some((arg) => arg.startsWith("*"))) {
          return `${node.callee.property.name}(${args.join(", ")})`;
        }
        return fn(args);
      }
    }
    // V2.12: `parseInt(x[, radix])` -> `int(x[, radix])`; `parseFloat(x)` ->
    // `float(x)`; `String(x)` -> `str(x)`. Covers the `Number.`-qualified
    // spellings. JS leading-digit leniency is NOT modeled (ValueError on junk).
    if (node.callee?.type === "Identifier" && !node.optional) {
      let cname = node.callee.name;
      if (cname === "Number" || cname === "String") {
        // `Number.parseInt` / `String.fromCharCode` shapes arrive as member
        // callees; only the bare wrappers land here.
      }
      if (cname === "String" && (node.arguments ?? []).length === 1) {
        const text = emitExpr(node.arguments[0], path, diags, ctx);
        if (text === null) return null;
        return `str(${text})`;
      }
      if (cname === "parseInt" && (node.arguments?.length === 1 || node.arguments?.length === 2)) {
        const args = [];
        for (const arg of node.arguments ?? []) {
          const text = emitExpr(arg, path, diags, ctx);
          if (text === null) return null;
          args.push(text);
        }
        return `int(${args.join(", ")})`;
      }
      if (cname === "parseFloat" && node.arguments?.length === 1) {
        const text = emitExpr(node.arguments[0], path, diags, ctx);
        if (text === null) return null;
        return `float(${text})`;
      }
    }
    // V2.12: `Number.parseInt(x[, r])` / `Number.parseFloat(x)` member forms.
    if (
      node.callee?.type === "MemberExpression"
      && !node.callee.computed
      && node.callee.object?.type === "Identifier"
      && node.callee.object.name === "Number"
      && node.callee.property?.type === "Identifier"
    ) {
      const m = node.callee.property.name;
      if ((m === "parseInt" && (node.arguments?.length === 1 || node.arguments?.length === 2))
        || (m === "parseFloat" && node.arguments?.length === 1)) {
        const fn = m === "parseInt" ? "int" : "float";
        const args = [];
        for (const arg of node.arguments ?? []) {
          const text = emitExpr(arg, path, diags, ctx);
          if (text === null) return null;
          args.push(text);
        }
        return `${fn}(${args.join(", ")})`;
      }
    }
    // V2.12: `/pat/.test(x)` -> `(search(r"pat", x) is not None)` — the
    // truthy-match-object form would leak Match|None into bool slots (E1001).
    // Also covers `.test` on a module-level regex-const name.
    const literalRegexCallee = node.callee?.type === "MemberExpression"
      && !node.callee.computed
      && node.callee.property?.type === "Identifier"
      && node.callee.property.name === "test"
      && node.callee.object?.type === "Literal"
      && node.callee.object.regex;
    const constRegexCallee = node.callee?.type === "MemberExpression"
      && !node.callee.computed
      && node.callee.property?.type === "Identifier"
      && node.callee.property.name === "test"
      && node.callee.object?.type === "Identifier"
      && REGEX_CONSTS.has(node.callee.object.name);
    if ((literalRegexCallee || constRegexCallee) && (node.arguments ?? []).length === 1
      && node.arguments[0].type !== "SpreadElement") {
      let patText = null;
      let flagArg = "";
      if (literalRegexCallee) {
        patText = pyRawString(node.callee.object.regex.pattern ?? "");
        flagArg = pyRegexFlagsArg(node.callee.object.regex.flags);
      } else {
        patText = node.callee.object.name;
      }
      const subject = emitExpr(node.arguments[0], path, diags, ctx);
      if (subject === null) return null;
      REGEX_INTEROP.search = true;
      return `(search(${patText}, ${subject}${flagArg}) is not None)`;
    }
    const callee = emitExpr(node.callee, path, diags, ctx);
    if (callee === null) return null;
    const args = [];
    for (const arg of node.arguments ?? []) {
      if (arg.type === "SpreadElement") {
        const val = emitExpr(arg.argument, path, diags, ctx);
        if (val === null) return null;
        args.push(`*${val}`);
        continue;
      }
      const text = emitExpr(arg, path, diags, ctx);
      if (text === null) return null;
      args.push(text);
    }
    const rawCallee = unwrapTsValue(node.callee);
    const callTarget = rawCallee?.type === "ArrowFunctionExpression" || rawCallee?.type === "FunctionExpression"
      ? `(${callee})`
      : callee;
    return `${callTarget}(${args.join(", ")})`;
  }
  if (kind === "ArrayExpression") {
    const elems = [];
    for (const el of node.elements ?? []) {
      if (el === null) {
        diags.push(diag("E7215", "Sparse array holes are not supported", path));
        return null;
      }
      if (el.type === "SpreadElement") {
        const val = emitExpr(el.argument, path, diags, ctx);
        if (val === null) return null;
        elems.push(`*${val}`);
        continue;
      }
      const text = emitExpr(el, path, diags, ctx);
      if (text === null) return null;
      elems.push(text);
    }
    return `[${elems.join(", ")}]`;
  }
  if (kind === "ObjectExpression") {
    const body = emitObjectLiteral(node, path, diags, ctx);
    if (body === null) return null;
    return `{${body}}`;
  }
  if (kind === "TemplateLiteral") return emitTemplateLiteral(node, path, diags, ctx);
  if (kind === "BinaryExpression") {
    const typeofGuard = tryLowerTypeofGuard(node, path, diags);
    if (typeofGuard !== undefined) return typeofGuard;
    if (node.operator === "??") {
      return emitNullishOnce(node, path, diags, ctx);
    }
    const op = BINARY_OPS[node.operator];
    if (op === undefined) {
      diags.push(diag("E7215", `Unsupported binary operator: ${node.operator}`, path));
      return null;
    }
    const left = emitExpr(node.left, path, diags, ctx);
    if (left === null) return null;
    const right = emitExpr(node.right, path, diags, ctx);
    if (right === null) return null;
    if (["&", "|", "^", "<<", ">>"].includes(node.operator)) {
      // JavaScript coerces bitwise operands to int32 but still exposes the
      // result as `number`; Jac's integer operators need explicit narrowing and
      // the surrounding float restores the TS-number contract.
      return `float(int(${left}) ${op} int(${right}))`;
    }
    return `(${left} ${op} ${right})`;
  }
  if (kind === "LogicalExpression") {
    if (node.operator === "??") {
      return emitNullishOnce(node, path, diags, ctx);
    }
    const op = LOGICAL_OPS[node.operator];
    if (op === undefined) {
      diags.push(diag("E7215", `Unsupported logical operator: ${node.operator}`, path));
      return null;
    }
    const left = emitExpr(node.left, path, diags, ctx);
    if (left === null) return null;
    const right = emitExpr(node.right, path, diags, ctx);
    if (right === null) return null;
    return `(${left} ${op} ${right})`;
  }
  if (kind === "UnaryExpression") {
    const op = UNARY_OPS[node.operator];
    if (op === undefined) {
      diags.push(diag("E7215", `Unsupported unary operator: ${node.operator}`, path));
      return null;
    }
    const arg = emitExpr(node.argument, path, diags, ctx);
    if (arg === null) return null;
    if (node.operator === "~") return `float(~int(${arg}))`;
    return `${op}${arg}`;
  }
  if (kind === "ConditionalExpression") {
    const test = emitExpr(node.test, path, diags, ctx);
    if (test === null) return null;
    const cons = emitExpr(node.consequent, path, diags, ctx);
    if (cons === null) return null;
    const alt = emitExpr(node.alternate, path, diags, ctx);
    if (alt === null) return null;
    return `(${cons} if ${test} else ${alt})`;
  }
  if (kind === "AssignmentExpression") {
    // Only simple/compound assignment between lowerable expressions. Used for
    // inline assignments (e.g. `x = y` as an expression statement body).
    if (node.operator === "=") {
      const left = emitExpr(node.left, path, diags, ctx);
      if (left === null) return null;
      const right = emitExpr(node.right, path, diags, ctx);
      if (right === null) return null;
      return `${left} = ${right}`;
    }
    diags.push(diag("E7215", `Compound/assignment operator ${node.operator} is not supported as an expression`, path));
    return null;
  }
  if (kind === "ArrowFunctionExpression" || kind === "FunctionExpression") {
    return emitCallbackLambda(node, path, diags, null, ctx);
  }
  if (kind === "Super") {
    return "super";
  }
  if (kind === "ThisExpression") {
    if (ctx.inClass) return "self";
    diags.push(diag("E7215", "`this` is not supported (component helpers must not rely on receiver binding)", path));
    return null;
  }
  if (kind === "UpdateExpression") {
    const arg = emitExpr(node.argument, path, diags, ctx);
    if (arg === null) return null;
    const delta = node.operator === "++" ? "1" : "-1";
    if (node.prefix) {
      diags.push(diag("E7215", "Prefix increment/decrement is not supported as an expression", path));
      return null;
    }
    return `${arg} + ${delta}`;
  }
  if (kind === "AwaitExpression") {
    // Fix 3: `await x` lowers 1:1 to Jac `await x`. Valid JS only permits
    // `await` lexically inside an async function, so any await reachable here is
    // in an async helper body we are emitting as `async def`. Nested async
    // callbacks are still rejected upstream (E7215), so this never leaks into a
    // sync context.
    const inner = emitExpr(node.argument, path, diags);
    if (inner === null) return null;
    return `await ${inner}`;
  }
  if (kind === "YieldExpression") {
    diags.push(diag("E7215", "generators (yield) are not supported in V2 expressions", path));
    return null;
  }
  if (kind === "SequenceExpression") {
    diags.push(diag("E7215", "Comma/sequence expressions are not supported", path));
    return null;
  }
  if (kind === "TaggedTemplateExpression") {
    diags.push(diag("E7215", "Tagged template expressions are not supported", path));
    return null;
  }
  diags.push(diag("E7215", `Unsupported expression in body: ${kind}`, path));
  return null;
}

/**
 * Emit an expression for preserved React interop (useMemo/useCallback). Extends
 * emitExpr with arrow/function callbacks and typed lambda parameters.
 */
function emitInteropExpr(node, path, diags) {
  const kind = node?.type ?? "";
  if (kind === "CallExpression") {
    const callee = emitInteropExpr(node.callee, path, diags);
    if (callee === null) return null;
    const args = [];
    for (const arg of node.arguments ?? []) {
      const text = emitInteropExpr(arg, path, diags);
      if (text === null) return null;
      args.push(text);
    }
    return `${callee}(${args.join(", ")})`;
  }
  if (kind === "ArrowFunctionExpression" || kind === "FunctionExpression") {
    if (node.generator || node.async) {
      diags.push(diag("E7215", "Async/generator callbacks are not supported in interop hooks", path));
      return null;
    }
    const paramParts = [];
    for (const param of node.params ?? []) {
      if (param.type !== "Identifier") {
        diags.push(diag("E7215", "Interop hook callbacks must use simple identifier parameters", path));
        return null;
      }
      let jacType = "any";
      const ann = param.typeAnnotation?.typeAnnotation;
      if (ann) {
        const mapped = tsTypeToJac(ann, path, diags);
        if (!mapped) return null;
        jacType = mapped;
      }
      paramParts.push(`${param.name}: ${jacType}`);
    }
    const paramText = paramParts.join(", ");
    if (node.body?.type === "BlockStatement") {
      const lines = [];
      for (const stmt of node.body.body ?? []) {
        if (stmt.type === "ReturnStatement") {
          const ret = emitInteropExpr(stmt.argument, path, diags);
          if (ret === null) return null;
          lines.push(`return ${ret}`);
        } else if (stmt.type === "ExpressionStatement") {
          const exprText = emitInteropExpr(stmt.expression, path, diags);
          if (exprText === null) return null;
          lines.push(`${exprText};`);
        } else {
          diags.push(diag("E7215", "Only return and expression statements are supported in interop hook callbacks", path));
          return null;
        }
      }
      return `lambda (${paramText}) -> any { ${lines.join(" ")} }`;
    }
    const bodyExpr = emitInteropExpr(node.body, path, diags);
    if (bodyExpr === null) return null;
    return `lambda (${paramText}) -> any { return ${bodyExpr}; }`;
  }
  return emitExpr(node, path, diags);
}

function recordInteropImport(callee, hookBindings, importState) {
  if (!importState) return;
  if (callee?.type === "Identifier") {
    importState.usedLocals.add(callee.name);
    return;
  }
  if (callee?.type === "MemberExpression" && !callee.computed) {
    const obj = callee.object;
    if (obj?.type === "Identifier" && hookBindings.namespaces.has(obj.name)) {
      importState.namespaceLocals.add(obj.name);
    }
  }
}

function formatReactImports(body, hookBindings, importState) {
  if (!importState) return [];
  const lines = [];
  const namedSpecs = [];
  for (const local of importState.usedLocals) {
    if (hookBindings.namespaces.has(local)) continue;
    const imported = hookBindings.aliases.get(local);
    if (imported) {
      namedSpecs.push(local === imported ? imported : `${imported} as ${local}`);
    } else if (SUPPORTED_HOOKS.has(local) || INTEROP_HOOKS.has(local)) {
      namedSpecs.push(local);
    }
  }
  if (namedSpecs.length) {
    lines.push(`import from react { ${namedSpecs.join(", ")} }`);
  }
  for (const local of importState.namespaceLocals) {
    const kind = hookBindings.namespaceKinds.get(local) ?? "namespace";
    if (kind === "default") {
      lines.push(`import from react { default as ${local} }`);
    } else {
      lines.push(`import from react { * as ${local} }`);
    }
  }
  return lines;
}

/** V2.6: collect non-react import declarations for interop preservation. React
 * imports are owned by `collectHookBindings`; everything else (npm packages,
 * relative modules, CSS/assets) is preserved here. */
/**
 * Collect names exported via a bare `export { A, B }` list (no `from` source).
 * These decouple a local declaration from its export, so the matching
 * function/const is emitted as public. Only identity specifiers count; aliased
 * (`A as B`) and re-export (`... from`) forms are left for the main loop to
 * diagnose.
 */
function collectBareExportNames(body) {
  const names = new Set();
  for (const item of body) {
    if (item.type !== "ExportNamedDeclaration") continue;
    if (item.declaration || item.source) continue;
    for (const spec of item.specifiers ?? []) {
      if (spec.type === "ExportSpecifier" && spec.local?.name === spec.exported?.name) {
        names.add(spec.local.name);
      }
    }
  }
  return names;
}

/**
 * V2.8: canonical symbol name for an anonymous `export default` (arrow or
 * unnamed function). The default is a cross-file symbol, so importers must
 * resolve it to a stable name; we derive it from the module basename (the
 * parent dir for `index` files) sanitized to a valid identifier. The graph
 * layer (`_default_export_symbol` in graph.impl.jac) MUST reproduce this rule
 * exactly so `default as X` import rewrites agree with what this module emits.
 */
function defaultExportBasename(path) {
  const parts = String(path ?? "").split(/[\\/]/).filter(Boolean);
  let base = (parts[parts.length - 1] ?? "").replace(/\.[^.]*$/, "");
  if (base === "index") {
    base = parts.length >= 2 ? parts[parts.length - 2].replace(/\.[^.]*$/, "") : "index";
  }
  base = base.replace(/[^A-Za-z0-9_]/g, "");
  if (!base) base = "Default";
  if (/^[0-9]/.test(base)) base = "_" + base;
  return base;
}

/** V2.12: rewrite relative JS module specifiers to sibling `.jac` files so
 * emitted imports resolve in project-mode `jac check`. Extensionless and
 * `.ts`/`.js`/`.mjs`/`.cjs` specifiers get `.jac`; package specifiers
 * (react, node:*, eventemitter) pass through untouched. */
function jacModulePath(src) {
  if (typeof src !== "string" || !src) return src;
  if (!src.startsWith("./") && !src.startsWith("../")) return src;
  if (/\.jac$/.test(src)) return src;
  return src.replace(/\.(ts|tsx|js|jsx|mjs|cjs)$/, "") + ".jac";
}

function collectInteropImports(body) {
  const out = [];
  for (const item of body) {
    if (item.type !== "ImportDeclaration") continue;
    if ((item.source?.value ?? "") === "react") continue;
    if (item.importKind === "type" || item.importKind === "typeof") continue;
    const specs = [];
    for (const s of item.specifiers ?? []) {
      if (s.type === "ImportDefaultSpecifier") {
        specs.push({ kind: "default", local: s.local?.name });
      } else if (s.type === "ImportNamespaceSpecifier") {
        specs.push({ kind: "namespace", local: s.local?.name });
      } else if (s.type === "ImportSpecifier") {
        if (s.importKind === "type" || s.importKind === "typeof") continue;
        const importedName = s.imported?.type === "Identifier" ? s.imported.name : s.imported?.value;
        specs.push({ kind: "named", imported: importedName, local: s.local?.name });
      }
    }
    out.push({ source: item.source?.value ?? "", specifiers: specs });
  }
  return out;
}

/** V2.6: emit non-react imports. Relative specifiers (./x, ../x) become live
 * Jac imports resolved to sibling `.jac` files (project mode). Bare package
 * specifiers (npm modules like `events`/`eventemitter3`) can never resolve as
 * `.jac` and would drag the module into client placement (E5084) — they emit
 * as inert interop comments instead. Side-effect imports are always comments. */
function formatInteropImports(imports) {
  const lines = [];
  for (const imp of imports) {
    const isRelative = imp.source.startsWith("./") || imp.source.startsWith("../");
    if (!imp.specifiers.length || !isRelative) {
      const specText = imp.specifiers.length
        ? ` { ${imp.specifiers.map((s) => (s.kind === "named" && s.imported === s.local ? s.local : s.local)).join(", ")} }`
        : "";
      lines.push(`# interop import: ${imp.source}${specText}`);
      continue;
    }
    const parts = imp.specifiers.map((s) => {
      if (s.kind === "default") return `default as ${s.local}`;
      if (s.kind === "namespace") return `* as ${s.local}`;
      return s.imported === s.local ? s.local : `${s.imported} as ${s.local}`;
    });
    lines.push(`import from "${jacModulePath(imp.source)}" { ${parts.join(", ")} }`);
  }
  return lines;
}

/**
 * Fail-open re-export lowering: a barrel-file re-export carries no local
 * declaration, only a re-binding from another module, which Jac expresses as a
 * plain import. `export { A, B as C } from './m'` -> `import from "./m" { A, B
 * as C }`; `export * from './m'` -> `import from "./m" { * }`; `export * as ns
 * from './m'` / `export { default as X } from './m'` handled by the specifier
 * mapping. Returns { line, exportedNames } or null when a specifier shape can't
 * be lowered soundly (caller falls back to the strict E7205). ESTree puts the
 * source-module name in `spec.local` and the outward name in `spec.exported`.
 */
function lowerReExport(item) {
  const src = jacModulePath(item.source?.value);
  if (typeof src !== "string" || !src) return null;
  const exportedNames = [];
  if (item.exportKind === "type" || item.exportKind === "typeof") {
    return { line: null, exportedNames };
  }
  if (item.type === "ExportAllDeclaration") {
    const ns = item.exported?.name ?? item.exported?.value;
    if (ns) { exportedNames.push(ns); return { line: `import from "${src}" { * as ${ns} }`, exportedNames }; }
    return { line: `import from "${src}" { * }`, exportedNames };
  }
  const parts = [];
  for (const spec of item.specifiers ?? []) {
    if (spec.exportKind === "type" || spec.exportKind === "typeof") continue;
    if (spec.type === "ExportSpecifier") {
      const local = spec.local?.name ?? spec.local?.value;
      const exp = spec.exported?.name ?? spec.exported?.value;
      if (!local || !exp) return null;
      parts.push(local === exp ? local : `${local} as ${exp}`);
      exportedNames.push(exp);
    } else if (spec.type === "ExportNamespaceSpecifier") {
      const exp = spec.exported?.name ?? spec.exported?.value;
      if (!exp) return null;
      parts.push(`* as ${exp}`);
      exportedNames.push(exp);
    } else {
      return null;
    }
  }
  if (!parts.length) return { line: null, exportedNames };
  return { line: `import from "${src}" { ${parts.join(", ")} }`, exportedNames };
}

const BINARY_OPS = {
  "+": "+", "-": "-", "*": "*", "/": "/", "%": "%", "**": "**",
  "&": "&", "|": "|", "^": "^", "<<": "<<", ">>": ">>",
  "==": "==", "!=": "!=",
  "===": "==", "!==": "!=",
  ">": ">", "<": "<", ">=": ">=", "<=": "<=",
  // Both languages define this as membership of the left value in the right
  // collection. Object prototype-chain details remain a runtime-model concern.
  "in": "in",
};
const LOGICAL_OPS = {
  "&&": "and",
  "||": "or",
};
const UNARY_OPS = {
  "!": "not ",
  "-": "-",
  "+": "+",
  "~": "~",
};

// JS `typeof X === 'string'` runtime type-guard idiom -> Jac `isinstance`. Only
// the unambiguous primitive typenames are mapped; `object`/`function`/`symbol`
// have no clean 1:1 Jac form and stay E7215 rather than guessing.
const TYPEOF_JAC_TYPE = {
  string: "str",
  number: "(int, float)",
  boolean: "bool",
  bigint: "int",
};

/**
 * Recognize `typeof X <eq> '<name>'` (either operand order) and lower it to a
 * Jac `isinstance(...)` / `is None` check. Returns:
 *   - a Jac string when the idiom is recognized and lowered,
 *   - null when recognized but the inner operand failed to lower (diag pushed),
 *   - undefined when this is NOT the typeof idiom (caller handles normally).
 */
function tryLowerTypeofGuard(node, path, diags) {
  const eq = node.operator === "===" || node.operator === "==";
  const ne = node.operator === "!==" || node.operator === "!=";
  if (!eq && !ne) return undefined;
  let unary = null;
  let lit = null;
  for (const [a, b] of [[node.left, node.right], [node.right, node.left]]) {
    const isStr = (b?.type === "StringLiteral" || b?.type === "Literal") && typeof b?.value === "string";
    if (a?.type === "UnaryExpression" && a.operator === "typeof" && isStr) {
      unary = a;
      lit = b;
      break;
    }
  }
  if (!unary) return undefined;
  const arg = emitExpr(unary.argument, path, diags);
  if (arg === null) return null;
  if (lit.value === "undefined") {
    return eq ? `(${arg} is None)` : `(${arg} is not None)`;
  }
  const jacType = TYPEOF_JAC_TYPE[lit.value];
  if (jacType === undefined) return undefined; // unknown typename -> fall through to E7215
  const check = `isinstance(${arg}, ${jacType})`;
  return eq ? check : `(not ${check})`;
}

/**
 * Infer the Jac `has` field type from a useState initializer literal.
 * Returns the type string, or null if the initializer is not a supported eager
 * literal (caller emits E7210).
 */
function inferStateType(initNode) {
  const kind = initNode?.type ?? "";
  if (kind === "Literal") {
    const v = initNode.value;
    if (typeof v === "string") return "str";
    if (typeof v === "number") return Number.isInteger(v) ? "int" : "float";
    if (typeof v === "boolean") return "bool";
    return null; // null and other literals are rejected
  }
  if (kind === "StringLiteral") return "str";
  if (kind === "NumericLiteral") return Number.isInteger(initNode.value) ? "int" : "float";
  if (kind === "BooleanLiteral") return "bool";
  if (kind === "ArrayExpression") return "list";
  if (kind === "ObjectExpression") return "dict";
  return null;
}

/**
 * Collect React hook import bindings from module-level `import ... from 'react'`.
 * Named imports map local alias -> canonical hook name; default/namespace imports
 * register the local binding for `Binding.useState`-style member callees.
 * Type-only imports and non-react sources are ignored.
 */
function collectHookBindings(body) {
  const aliases = new Map();
  const namespaces = new Set();
  const namespaceKinds = new Map();
  // Fix 6: local names bound to a NON-react import (npm package or local file).
  // A `useX` callee resolving here is provenance-not-react, so it is an ordinary
  // interop call, not a React core hook — it must NOT be classified as a hook
  // (which would fail-close with E7208). Value bindings only; type-only imports
  // are excluded (they never appear as call callees).
  const interopLocals = new Set();
  for (const item of body) {
    if (item.type !== "ImportDeclaration") continue;
    if (item.importKind === "type" || item.importKind === "typeof") continue;
    if (item.source?.value !== "react") {
      for (const spec of item.specifiers ?? []) {
        if (spec.importKind === "type" || spec.importKind === "typeof") continue;
        const localName = spec.local?.name;
        if (localName) interopLocals.add(localName);
      }
      continue;
    }
    for (const spec of item.specifiers ?? []) {
      const localName = spec.local?.name;
      if (!localName) continue;
      if (spec.type === "ImportSpecifier") {
        const importedName = spec.imported?.type === "Identifier"
          ? spec.imported.name
          : spec.imported?.value;
        if (!importedName) continue;
        if (/^use[A-Z]/.test(importedName) || importedName === "forwardRef" || importedName === "memo") {
          aliases.set(localName, importedName);
        }
      } else if (spec.type === "ImportDefaultSpecifier") {
        namespaces.add(localName);
        namespaceKinds.set(localName, "default");
      } else if (spec.type === "ImportNamespaceSpecifier") {
        namespaces.add(localName);
        namespaceKinds.set(localName, "namespace");
      }
    }
  }
  return { aliases, namespaces, namespaceKinds, interopLocals };
}

/** Resolve a hook call callee to its canonical React hook name. */
function resolveHookCallee(callee, hookBindings) {
  if (callee?.type === "Identifier") {
    const name = callee.name;
    if (hookBindings.aliases.has(name)) return hookBindings.aliases.get(name);
    if (SUPPORTED_HOOKS.has(name)) return name;
    // Fix 6: provenance gate. A `useX` bound to a non-react import (npm package
    // or local file) is an ordinary interop call — return null so it flows
    // through the normal call/interop path instead of the React-hook path
    // (which would reject it with E7208). Only genuinely-react or unimported
    // `useX` names remain classified as hooks (kept fail-closed at E7208).
    if (hookBindings.interopLocals?.has(name)) return null;
    if (/^use[A-Z]/.test(name)) return name;
    return null;
  }
  if (callee?.type === "MemberExpression" && !callee.computed) {
    const obj = callee.object;
    const prop = callee.property;
    if (
      obj?.type === "Identifier"
      && prop?.type === "Identifier"
      && hookBindings.namespaces.has(obj.name)
      && /^use[A-Z]/.test(prop.name)
    ) {
      return prop.name;
    }
  }
  return null;
}

function hookNameOfCall(call, hookBindings) {
  if (call?.type !== "CallExpression") return null;
  return resolveHookCallee(call.callee, hookBindings);
}

/**
 * Recognize and lower `const/let [name, setter] = useState(<init>);` to a
 * component-local `has name: T = init;`. Returns:
 *   { state: "has", name, setter, type, initText } on success
 *   { state: "other" } if the statement is not a useState declaration
 *   null if it is a useState declaration but rejected (diagnostic already pushed)
 */
function parseUseStateDecl(stmt, path, diags, hookBindings) {
  if (stmt?.type !== "VariableDeclaration") return { state: "other" };
  if (stmt.kind !== "const" && stmt.kind !== "let") return { state: "other" };
  const declarators = stmt.declarations ?? [];
  if (declarators.length !== 1) return { state: "other" };
  const declarator = declarators[0];
  const id = declarator.id;
  if (id?.type !== "ArrayPattern") return { state: "other" };
  const elements = id.elements ?? [];
  if (elements.length !== 2) return { state: "other" };
  const nameNode = elements[0];
  const setterNode = elements[1];
  if (nameNode?.type !== "Identifier" || setterNode?.type !== "Identifier") {
    return { state: "other" };
  }
  const init = declarator.init;
  if (init?.type !== "CallExpression") return { state: "other" };
  if (resolveHookCallee(init.callee, hookBindings) !== "useState") {
    return { state: "other" };
  }
  // Recognized as useState from here on; any shortfall is a rejection, not "other".
  const args = init.arguments ?? [];
  if (args.length === 0) {
    diags.push(diag("E7210", "useState requires an eager literal initializer", path));
    return null;
  }
  const initArg = args[0];
  if (initArg.type === "ArrowFunctionExpression" || initArg.type === "FunctionExpression") {
    diags.push(diag("E7210", "useState lazy initializer is not supported (use an eager literal)", path));
    return null;
  }
  const typeStr = inferStateType(initArg);
  if (!typeStr) {
    diags.push(diag("E7210", "useState initializer must be a literal (string, number, boolean, [], or {})", path));
    return null;
  }
  // Empty list/dict must stay empty; non-empty composite literals are deferred.
  if ((initArg.type === "ArrayExpression" || initArg.type === "ObjectExpression")
      && (initArg.elements ?? initArg.properties ?? []).length > 0) {
    diags.push(diag("E7210", "useState non-empty composite initializer is not supported", path));
    return null;
  }
  const initText = emitExpr(initArg, path, diags);
  if (initText === null) return null;
  return { state: "has", name: nameNode.name, setter: setterNode.name, type: typeStr, initText };
}

/**
 * Preserve `const v = useMemo(...)` / `useCallback(...)` as interop assignments.
 */
function parseInteropHookDecl(stmt, path, diags, hookBindings, importState) {
  if (stmt?.type !== "VariableDeclaration") return { state: "other" };
  if (stmt.kind !== "const" && stmt.kind !== "let") return { state: "other" };
  const declarators = stmt.declarations ?? [];
  if (declarators.length !== 1) return { state: "other" };
  const declarator = declarators[0];
  const id = declarator.id;
  if (id?.type !== "Identifier") return { state: "other" };
  const init = declarator.init;
  if (init?.type !== "CallExpression") return { state: "other" };
  const hook = resolveHookCallee(init.callee, hookBindings);
  if (!hook || !INTEROP_HOOKS.has(hook)) return { state: "other" };
  recordInteropImport(init.callee, hookBindings, importState);
  const initText = emitInteropExpr(init, path, diags);
  if (initText === null) return null;
  return {
    state: "interop",
    hook,
    line: `${id.name} = ${initText};`,
  };
}

/**
 * Emit a plain component-body / effect-body statement that is a call: either a
 * tracked useState setter (rewritten to direct assignment) or an interop call
 * (preserved verbatim). Returns the Jac line (without trailing newline) or null.
 */
function emitCallStatement(stmt, setterMap, path, diags) {
  if (stmt?.type !== "ExpressionStatement") return null;
  const call = stmt.expression;
  if (call?.type !== "CallExpression") return null;
  if (call.callee?.type === "Identifier" && call.callee.name in setterMap) {
    const args = call.arguments ?? [];
    if (args.length !== 1) {
      diags.push(diag("E7209", "useState setter must be called with exactly one value argument", path));
      return null;
    }
    const arg = args[0];
    if (arg.type === "ArrowFunctionExpression" || arg.type === "FunctionExpression") {
      diags.push(diag("E7209", "useState functional updater is not supported; use a direct value", path));
      return null;
    }
    const argText = emitExpr(arg, path, diags);
    if (argText === null) return null;
    return `${setterMap[call.callee.name]} = ${argText};`;
  }
  // Interop call: preserve the call verbatim as a client-side statement.
  const text = emitExpr(call, path, diags);
  if (text === null) return null;
  return `${text};`;
}

/**
 * Lower one useEffect dependency element to the Jac dep-list spelling.
 * Accepts a useState field name, the component prop parameter, or `param.field`.
 */
function parseEffectDep(dep, stateNames, propContext, path, diags) {
  if (!dep) {
    diags.push(diag("E7212", "useEffect dependency array may not contain holes", path));
    return null;
  }
  if (dep.type === "Identifier") {
    if (stateNames.has(dep.name)) return dep.name;
    if (propContext.mode === "props" && propContext.propParamName && dep.name === propContext.propParamName) {
      return propContext.propParamName;
    }
    if (propContext.mode === "named" && propContext.propNames.has(dep.name)) {
      return dep.name;
    }
  }
  if (
    propContext.mode === "props"
    && propContext.propParamName
    && dep.type === "MemberExpression"
    && !dep.computed
    && dep.object?.type === "Identifier"
    && dep.object.name === propContext.propParamName
    && dep.property?.type === "Identifier"
  ) {
    return `${propContext.propParamName}.${dep.property.name}`;
  }
  diags.push(diag(
    "E7212",
    "useEffect dependencies must be useState field names or prop names (or props.name when using a props bag); refs, deep member access, calls, and literals are not supported",
    path
  ));
  return null;
}

/**
 * Recognize and lower `useEffect(() => { ... }, deps)` to a Jac entry ability.
 * An empty dep array lowers to `can with entry`; a non-empty array lowers to
 * `can with [d1, d2] entry` where every dep is a useState `has` field declared
 * earlier in the component, the prop parameter itself, or a one-level
 * `param.field` member access (fail-closed: ref fields, deep member access,
 * calls, and literals are rejected). Returns:
 *   { state: "effect", header, deps, lines: [...] } on success
 *   { state: "other" } if the statement is not a useEffect call
 *   null if it is a useEffect call but rejected (diagnostic already pushed)
 */
function parseUseEffectStmt(stmt, setterMap, stateNames, propContext, path, diags, hookBindings) {
  if (stmt?.type !== "ExpressionStatement") return { state: "other" };
  const call = stmt.expression;
  if (call?.type !== "CallExpression") return { state: "other" };
  if (resolveHookCallee(call.callee, hookBindings) !== "useEffect") {
    return { state: "other" };
  }
  const args = call.arguments ?? [];
  if (args.length < 1) {
    diags.push(diag("E7213", "useEffect requires a callback arrow function", path));
    return null;
  }
  const callback = args[0];
  if (callback?.type !== "ArrowFunctionExpression") {
    diags.push(diag("E7213", "useEffect callback must be an inline arrow function", path));
    return null;
  }
  if ((callback.params ?? []).length > 0) {
    diags.push(diag("E7213", "useEffect callback must take no parameters", path));
    return null;
  }
  if (callback.body?.type !== "BlockStatement") {
    diags.push(diag("E7213", "useEffect callback must use a block body", path));
    return null;
  }
  // Dependency array. Empty -> `can with entry`. Non-empty -> `can with [...]`
  // entry, but every element must be a plain identifier naming a useState `has`
  // field declared earlier in the component. Anything else (a prop, a ref field,
  // member access, a call, a literal) is rejected so the dataset never records a
  // dep it cannot prove maps to reactive state.
  if (args.length < 2 || args[1]?.type !== "ArrayExpression") {
    diags.push(diag("E7212", "useEffect requires a dependency array ([] for mount-only, or state-field names)", path));
    return null;
  }
  const depElems = args[1].elements ?? [];
  const depNames = [];
  for (const dep of depElems) {
    const depName = parseEffectDep(dep, stateNames, propContext, path, diags);
    if (depName === null) return null;
    depNames.push(depName);
  }
  const header = depNames.length ? `can with [${depNames.join(", ")}] entry` : "can with entry";
  const innerStmts = callback.body.body ?? [];
  const lines = [];
  for (const inner of innerStmts) {
    if (inner.type === "ReturnStatement") {
      diags.push(diag("E7211", "useEffect cleanup return is not supported", path));
      return null;
    }
    const line = emitCallStatement(inner, setterMap, path, diags);
    if (line === null) {
      // emitCallStatement only rejects calls; a non-call statement is unsupported.
      if (!diags.length || diags[diags.length - 1].code !== "E7215") {
        diags.push(diag("E7214", "Unsupported statement in useEffect body (only calls are allowed)", path));
      }
      return null;
    }
    lines.push(line);
  }
  return { state: "effect", header, deps: depNames, lines };
}

/**
 * Recognize and lower `const/let r = useRef(...)` to a component-local ref
 * field. `useRef(<literal>)` -> `has r: Ref[T] = Ref(<literal>)` with T inferred
 * from the literal; `useRef(null)` / `useRef(undefined)` / `useRef()` ->
 * `has r: Ref = Ref()` (the empty DOM-ref form). Returns:
 *   { state: "ref", name, type, initText } on success
 *   { state: "other" } if the statement is not a useRef declaration
 *   null if it is a useRef declaration but rejected (diagnostic already pushed)
 */
function parseUseRefDecl(stmt, path, diags, hookBindings) {
  if (stmt?.type !== "VariableDeclaration") return { state: "other" };
  if (stmt.kind !== "const" && stmt.kind !== "let") return { state: "other" };
  const declarators = stmt.declarations ?? [];
  if (declarators.length !== 1) return { state: "other" };
  const declarator = declarators[0];
  if (declarator.id?.type !== "Identifier") return { state: "other" };
  const init = declarator.init;
  if (init?.type !== "CallExpression") return { state: "other" };
  if (resolveHookCallee(init.callee, hookBindings) !== "useRef") {
    return { state: "other" };
  }
  const args = init.arguments ?? [];
  if (args.length > 1) {
    diags.push(diag("E7216", "useRef takes at most one initializer argument", path));
    return null;
  }
  // No argument, or an explicit null/undefined initializer: empty DOM ref.
  if (args.length === 0) {
    return { state: "ref", name: declarator.id.name, type: "Ref", initText: "Ref()" };
  }
  const arg = args[0];
  const isNull = (arg.type === "Literal" && arg.value === null) || arg.type === "NullLiteral";
  const isUndefined = arg.type === "Identifier" && arg.name === "undefined";
  if (isNull || isUndefined) {
    return { state: "ref", name: declarator.id.name, type: "Ref", initText: "Ref()" };
  }
  // Value ref: infer T from the eager literal initializer.
  const typeStr = inferStateType(arg);
  if (!typeStr) {
    diags.push(diag("E7216", "useRef initializer must be a literal (string, number, boolean, [], or {})", path));
    return null;
  }
  if ((arg.type === "ArrayExpression" || arg.type === "ObjectExpression")
      && (arg.elements ?? arg.properties ?? []).length > 0) {
    diags.push(diag("E7216", "useRef non-empty composite initializer is not supported", path));
    return null;
  }
  const initText = emitExpr(arg, path, diags);
  if (initText === null) return null;
  return { state: "ref", name: declarator.id.name, type: `Ref[${typeStr}]`, initText: `Ref(${initText})` };
}

/**
 * Parse a component body (block or arrow expression body) into the structured
 * elements emitted by emitComponent. Enforces the hook ordering rule:
 * useState/useRef/useEffect declarations must precede any other statement, and
 * the body ends in exactly one `return <jsx>;`.
 */
function parseComponentBody(body, path, diags, hookBindings, propContext = { mode: "props", propParamName: "" }, importState = null) {
  if (body?.type === "JSXElement") {
    const jsxMappings = [];
    const jsxText = parseJsxElement(body, path, diags, jsxMappings);
    if (jsxText === null) return null;
    return { hasFields: [], interopStmts: [], abilities: [], stmts: [], returnJsx: jsxText, setterMap: {}, jsxMappings };
  }
  if (body?.type !== "BlockStatement") {
    diags.push(diag("E7205", `Unsupported component return form: ${body?.type}`, path));
    return null;
  }
  const stmts = body.body ?? [];
  const hasFields = [];
  const interopStmts = [];
  const abilities = [];
  const groupStmts = [];
  const setterMap = {};
  const stateNames = new Set();
  const jsxMappings = [];
  const dictBindings = new Set();
  let returnJsx = null;
  let declsClosed = false;
  for (let i = 0; i < stmts.length; i++) {
    const stmt = stmts[i];
    if (stmt.type === "ReturnStatement") {
      if (i !== stmts.length - 1) {
        diags.push(diag("E7214", "return must be the final statement in a component body", path));
        return null;
      }
      const jsxText = parseJsxElement(stmt.argument, path, diags, jsxMappings);
      if (jsxText === null) return null;
      returnJsx = jsxText;
      break;
    }
    // Unsupported React hook (precise E7208) — checked before the useState/useEffect
    // handlers so useRef/useMemo/useReducer/etc. are not misreported as generic statements.
    if (stmt.type === "VariableDeclaration") {
      for (const d of stmt.declarations ?? []) {
        const hook = hookNameOfCall(d.init, hookBindings);
        if (hook && hook !== "useState" && hook !== "useRef" && !INTEROP_HOOKS.has(hook)) {
          diags.push(diag("E7208", `Unsupported React hook '${hook}' (only useState, useRef, useEffect, useMemo, and useCallback are supported)`, path));
          return null;
        }
      }
    }
    if (stmt.type === "ExpressionStatement") {
      const hook = hookNameOfCall(stmt.expression, hookBindings);
      if (hook && hook !== "useEffect" && !INTEROP_HOOKS.has(hook)) {
        diags.push(diag("E7208", `Unsupported React hook '${hook}' (only mount-only useEffect is supported)`, path));
        return null;
      }
    }
    const useState = parseUseStateDecl(stmt, path, diags, hookBindings);
    if (useState === null) return null;
    if (useState.state === "has") {
      if (declsClosed) {
        diags.push(diag("E7214", "useState must appear before other statements in the component body", path));
        return null;
      }
      hasFields.push({ name: useState.name, type: useState.type, initText: useState.initText, origin: "state" });
      setterMap[useState.setter] = useState.name;
      stateNames.add(useState.name);
      continue;
    }
    const useRef = parseUseRefDecl(stmt, path, diags, hookBindings);
    if (useRef === null) return null;
    if (useRef.state === "ref") {
      if (declsClosed) {
        diags.push(diag("E7214", "useRef must appear before other statements in the component body", path));
        return null;
      }
      hasFields.push({ name: useRef.name, type: useRef.type, initText: useRef.initText, origin: "ref" });
      continue;
    }
    const interopHook = parseInteropHookDecl(stmt, path, diags, hookBindings, importState);
    if (interopHook === null) return null;
    if (interopHook.state === "interop") {
      if (declsClosed) {
        diags.push(diag("E7214", "useMemo/useCallback must appear before other statements in the component body", path));
        return null;
      }
      interopStmts.push({ hook: interopHook.hook, line: interopHook.line });
      continue;
    }
    const useEffect = parseUseEffectStmt(stmt, setterMap, stateNames, propContext, path, diags, hookBindings);
    if (useEffect === null) return null;
    if (useEffect.state === "effect") {
      if (declsClosed) {
        diags.push(diag("E7214", "useEffect must appear before other statements in the component body", path));
        return null;
      }
      abilities.push({ header: useEffect.header, deps: useEffect.deps, lines: useEffect.lines });
      continue;
    }
    // useState setter call -> rewrite to direct field assignment. Must precede
    // the general emitter so setters stay assignments rather than plain calls.
    if (stmt.type === "ExpressionStatement"
        && stmt.expression?.type === "CallExpression"
        && stmt.expression.callee?.type === "Identifier"
        && Object.prototype.hasOwnProperty.call(setterMap, stmt.expression.callee.name)) {
      const line = emitCallStatement(stmt, setterMap, path, diags);
      if (line === null) return null;
      declsClosed = true;
      groupStmts.push(line);
      continue;
    }
    // Fix 6: flat array/object destructuring of an interop return
    // (`const [play, dur] = useSound(url)`, `const { stop } = useX()`) is lowered
    // by emitStatement via lowerFlatPattern. Nested/rename/rest patterns are not
    // flat and stay fail-closed there (E7231). Everything else falls through.
    // V2.2 + V2.3: general statement — local const/let, control flow, calls,
    // expression statements. Components keep a single JSX return (handled above),
    // so nested returns are rejected via allowReturn=false.
    const lines = emitStatement(stmt, { path, diags, allowReturn: false, dictBindings });
    if (lines === null) {
      if (!diags.length) diags.push(diag("E7214", "Unsupported statement in component body", path));
      return null;
    }
    declsClosed = true;
    for (const l of lines) groupStmts.push(l);
    continue;
  }
  if (returnJsx === null) {
    diags.push(diag("E7205", "Components must end in a single return of JSX", path));
    return null;
  }
  return { hasFields, interopStmts, abilities, stmts: groupStmts, returnJsx, setterMap, jsxMappings };
}

function formatParamList(sig) {
  let base;
  if (sig.mode === "named") {
    const parts = sig.params.map((p) => {
      let text = `${p.name}: ${p.type}`;
      if (p.default) text += ` = ${p.default}`;
      return text;
    });
    base = `(${parts.join(", ")})`;
  } else if (sig.name) {
    base = `(${sig.name}: ${sig.type})`;
  } else {
    base = "()";
  }
  if (!sig.refParam) return base;
  if (base === "()") return `(ref: ${sig.refParam.type})`;
  return `${base.slice(0, -1)}, ref: ${sig.refParam.type})`;
}

function emitComponent(name, sig, comp, exported) {
  const pubKw = exported === false ? "" : ":pub";
  const paramPart = formatParamList(sig);
  const lines = [`def${pubKw} ${name}${paramPart} -> JsxElement {`];
  for (const f of comp.hasFields) {
    const initPart = f.initText ? ` = ${f.initText}` : "";
    lines.push(`    has ${f.name}: ${f.type}${initPart};`);
  }
  for (const hook of comp.interopStmts ?? []) {
    lines.push(`    ${hook.line}`);
  }
  for (const ab of comp.abilities) {
    lines.push(`    ${ab.header} {`);
    for (const l of ab.lines) lines.push(`        ${l}`);
    lines.push(`    }`);
  }
  for (const s of comp.stmts) lines.push(`    ${s}`);
  lines.push(`    return ${comp.returnJsx};`);
  lines.push("}");
  const jac = `${lines.join("\n")}\n`;

  const mappings = [
    { rule_id: exported === false ? "js.function.component.v2" : "react.component.export-function.v1", mapping_class: "exact", target: `def${pubKw} ${name}` },
    { rule_id: "jsx.element.intrinsic.v1", mapping_class: "exact", target: "JsxElement" },
  ];
  if (sig.fcUnwrapped) {
    mappings.push({
      rule_id: "react.component.fc-strip.v1",
      mapping_class: "guarded",
      target: "React.FC props type",
    });
  }
  if (sig.forwardRefUnwrapped) {
    mappings.push({
      rule_id: "react.component.forward-ref-strip.v1",
      mapping_class: "guarded",
      target: "trailing ref: Ref[T]",
    });
  }
  if (sig.memoUnwrapped) {
    mappings.push({
      rule_id: "react.component.memo-strip.v1",
      mapping_class: "guarded",
      target: "memo wrapper stripped",
    });
  }
  if (sig.mode === "named") {
    mappings.push({
      rule_id: "react.component.props-destructure.v1",
      mapping_class: "guarded",
      target: "named parameters",
    });
    if (sig.params.some((p) => p.name === "children" && isChildrenJacType(p.type))) {
      mappings.push({
        rule_id: "react.component.children-prop.v1",
        mapping_class: "exact",
        target: "children: any",
      });
    }
  } else if (sig.type.includes("children:")) {
    mappings.push({
      rule_id: "react.component.children-prop.v1",
      mapping_class: "exact",
      target: "children: any",
    });
  }
  for (const f of comp.hasFields) {
    mappings.push({
      rule_id: f.origin === "ref" ? "react.ref.useref.v1" : "react.state.usestate.v1",
      mapping_class: "guarded",
      target: `component has field ${f.name}`,
    });
  }
  for (const ab of comp.abilities) {
    const ruleId = (ab.deps && ab.deps.length)
      ? "react.effect.useeffect-deps.v1"
      : "react.effect.useeffect-mount.v1";
    mappings.push({
      rule_id: ruleId,
      mapping_class: "guarded",
      target: ab.header,
    });
  }
  for (const hook of comp.interopStmts ?? []) {
    mappings.push({
      rule_id: `react.hook.${hook.hook.toLowerCase()}.interop.v1`,
      mapping_class: "interop",
      target: `preserved ${hook.hook} call`,
    });
  }
  for (const m of comp.jsxMappings ?? []) mappings.push(m);
  return { jac, mappings };
}

/** V2.1: a function/arrow is a component when its final top-level return
 * yields a JSX element (or its arrow expression body is JSX). Everything else
 * lowers as a plain helper `def`. */
function bodyReturnsJsx(body) {
  if (!body) return false;
  if (isJsxNode(body)) return true;
  if (body.type === "BlockStatement") {
    const arr = body.body ?? [];
    if (!arr.length) return false;
    const last = arr[arr.length - 1];
    return last?.type === "ReturnStatement" && isJsxNode(last.argument);
  }
  return false;
}

/** Best-effort Jac return-type inference for helpers without a TS annotation. Only
 * literal/JSX/composite literal shapes are inferrable losslessly; anything else
 * returns null so the caller rejects (E7233) rather than widening to `any`. */
function inferExprType(node, path, diags) {
  const kind = node?.type ?? "";
  if (kind === "Literal") {
    const v = node.value;
    if (typeof v === "string") return "str";
    if (typeof v === "number") return Number.isInteger(v) ? "int" : "float";
    if (typeof v === "boolean") return "bool";
    if (v === null) return "None";
    return null;
  }
  if (kind === "StringLiteral") return "str";
  if (kind === "NumericLiteral") return Number.isInteger(node.value) ? "int" : "float";
  if (kind === "BooleanLiteral") return "bool";
  if (kind === "NullLiteral") return "None";
  if (kind === "TemplateLiteral") return "str";
  if (kind === "CallExpression"
    && node.callee?.type === "MemberExpression" && !node.callee.computed
    && JS_STRING_METHODS[node.callee.property?.name]) return "str";
  if (kind === "ArrayExpression") return "list";
  if (kind === "ObjectExpression") return "dict";
  if (isJsxNode(node)) return "JsxElement";
  return null;
}

function collectFloatLocals(body) {
  const numericLocals = new Set();
  const floatLocals = new Set();
  const declarations = [];
  const assignments = [];
  const walk = (node, visit) => {
    if (!node || typeof node !== "object") return;
    if (Array.isArray(node)) { for (const item of node) walk(item, visit); return; }
    if (node !== body && (node.type === "FunctionDeclaration" || node.type === "FunctionExpression"
      || node.type === "ArrowFunctionExpression")) return;
    visit(node);
    for (const [key, value] of Object.entries(node)) {
      if (key === "type" || key === "loc" || key === "range" || key === "start" || key === "end") continue;
      walk(value, visit);
    }
  };
  walk(body, (node) => {
    if (node.type !== "VariableDeclarator" || node.id?.type !== "Identifier" || node.id.typeAnnotation) return;
    const init = unwrapTsValue(node.init);
    declarations.push({ name: node.id.name, init });
    if ((init?.type === "Literal" && typeof init.value === "number") || init?.type === "NumericLiteral") {
      numericLocals.add(node.id.name);
    }
    if (init?.type === "CallExpression" && init.callee?.type === "Identifier"
      && NUMBER_RETURNING_FUNCS.has(init.callee.name)) {
      numericLocals.add(node.id.name);
      floatLocals.add(node.id.name);
    }
  });
  const suggestsFloat = (node) => {
    const value = unwrapTsValue(node);
    if (!value) return false;
    if ((value.type === "Literal" && typeof value.value === "number") || value.type === "NumericLiteral") {
      return !Number.isInteger(value.value);
    }
    if (value.type === "Identifier") return floatLocals.has(value.name);
    if (value.type === "CallExpression") {
      return value.callee?.type !== "Identifier" || NUMBER_RETURNING_FUNCS.has(value.callee.name);
    }
    if (value.type === "MemberExpression" || value.type === "OptionalMemberExpression") {
      return value.computed || value.property?.name !== "length";
    }
    if (value.type === "BinaryExpression" || value.type === "LogicalExpression") {
      return suggestsFloat(value.left) || suggestsFloat(value.right);
    }
    if (value.type === "UnaryExpression") return suggestsFloat(value.argument);
    return false;
  };
  const suggestsDeclaredFloat = (node) => {
    const value = unwrapTsValue(node);
    if (!value) return false;
    if (value.type === "Identifier") return floatLocals.has(value.name);
    if (value.type === "CallExpression") {
      return value.callee?.type === "Identifier" && NUMBER_RETURNING_FUNCS.has(value.callee.name);
    }
    if (value.type === "BinaryExpression" || value.type === "LogicalExpression") {
      return suggestsDeclaredFloat(value.left) || suggestsDeclaredFloat(value.right);
    }
    return false;
  };
  walk(body, (node) => {
    if (node.type === "AssignmentExpression" && node.left?.type === "Identifier") assignments.push(node);
  });
  // Type flow reaches a fixed point: helper result -> alias -> accumulator.
  // This is intentionally local to one function and never crosses callbacks.
  let changed = true;
  while (changed) {
    changed = false;
    for (const { name, init } of declarations) {
      if (!floatLocals.has(name) && suggestsDeclaredFloat(init)) {
        numericLocals.add(name);
        floatLocals.add(name);
        changed = true;
      }
    }
    for (const assignment of assignments) {
      const name = assignment.left.name;
      if (numericLocals.has(name) && !floatLocals.has(name) && suggestsFloat(assignment.right)) {
        floatLocals.add(name);
        changed = true;
      }
    }
  }
  return floatLocals;
}

function inferReturnTypeFromBody(body, path, diags) {
  if (!body) return null;
  if (body.type !== "BlockStatement") return inferExprType(body, path, diags);
  for (const s of body.body ?? []) {
    if (s.type === "ReturnStatement") {
      if (s.argument === null || s.argument === undefined) return "None";
      return inferExprType(s.argument, path, diags);
    }
  }
  return "None";
}

function isClassFieldMember(member) {
  const t = member?.type ?? "";
  return t === "ClassProperty" || t === "ClassPrivateProperty"
    || t === "PropertyDefinition" || t === "PrivateProperty";
}

function isClassMethodMember(member) {
  const t = member?.type ?? "";
  return t === "ClassMethod" || t === "ClassPrivateMethod"
    || t === "MethodDefinition";
}

function normalizeClassMethodMember(member) {
  if (member?.type === "MethodDefinition" && member.value) {
    const v = member.value;
    return {
      ...member,
      type: "ClassMethod",
      body: v.body,
      params: v.params ?? [],
      generator: v.generator ?? false,
      async: v.async ?? false,
      returnType: v.returnType ?? member.returnType,
    };
  }
  return member;
}

function isStaticLiteralInit(node) {
  const n = unwrapTsValue(node);
  if (!n) return false;
  switch (n.type) {
    case "Literal":
      if (n.regex !== undefined) return false;
      return typeof n.value === "string" || typeof n.value === "number"
        || typeof n.value === "boolean" || n.value === null;
    case "StringLiteral":
    case "NumericLiteral":
    case "BooleanLiteral":
    case "NullLiteral":
      return true;
    default:
      return false;
  }
}

function parseClassExtends(superClass, path, diags) {
  if (!superClass) return null;
  if (superClass.type === "Identifier") return superClass.name;
  diags.push(diag("E7205", `Unsupported class extends form: ${superClass.type}`, path));
  return null;
}

function parseClassMethodParams(params, path, diags, ctx) {
  const jacParams = [];
  for (const p of params ?? []) {
    let idNode = p;
    let defaultText = null;
    if (p?.type === "AssignmentPattern") {
      idNode = p.left;
      if (idNode?.type !== "Identifier") {
        diags.push(diag("E7232", "Class method default parameters must bind a simple identifier", path));
        return null;
      }
      const d = emitExpr(p.right, path, diags, ctx);
      if (d === null) return null;
      defaultText = d;
    } else if (p?.type === "RestElement") {
      diags.push(diag("E7232", "Class method rest parameters are not supported", path));
      return null;
    } else if (p?.type === "ObjectPattern" || p?.type === "ArrayPattern") {
      diags.push(diag("E7232", `Unsupported class method parameter form: ${p.type}`, path));
      return null;
    } else if (p?.type !== "Identifier") {
      diags.push(diag("E7232", `Unsupported class method parameter form: ${p?.type}`, path));
      return null;
    }
    const ann = idNode.typeAnnotation?.typeAnnotation;
    let baseType = ann ? tsTypeToJac(ann, path, diags) : null;
    if (!baseType && p?.type === "AssignmentPattern") {
      baseType = inferExprType(p.right, path, diags);
      // TypeScript numeric literals inhabit `number`, including integer-looking
      // defaults whose callers may still supply fractional values.
      if (baseType === "int") baseType = "float";
    }
    baseType ??= "any";
    if (!baseType) return null;
    const jacType = idNode.optional ? withOptionalJacType(baseType) : baseType;
    let text = `${identText(idNode.name)}: ${jacType}`;
    if (defaultText !== null) text += ` = ${defaultText}`;
    else if (idNode.optional) text += " = None";
    jacParams.push(text);
  }
  return jacParams;
}

function tryEmitCStyleFor(stmt, ctx) {
  const { path, diags } = ctx;
  const INDENT = "    ";
  const init = stmt.init;
  const test = stmt.test;
  const update = stmt.update;
  if (!test || !update) return null;
  let varName = null;
  let initVal = "0";
  if (init?.type === "VariableDeclaration" && init.kind === "let"
    && init.declarations?.length === 1) {
    const d = init.declarations[0];
    if (d.id?.type === "Identifier") {
      varName = d.id.name;
      if (d.init) {
        initVal = emitExpr(d.init, path, diags, ctx);
        if (initVal === null) return null;
      }
    }
  }
  if (!varName) return null;
  const testText = emitExpr(test, path, diags, ctx);
  if (testText === null) return null;
  let updateLine = null;
  if (update.type === "UpdateExpression"
    && update.argument?.type === "Identifier"
    && update.argument.name === varName) {
    const delta = update.operator === "++" ? "1" : "-1";
    updateLine = `${varName} += ${delta};`;
  } else if (update.type === "AssignmentExpression"
    && update.left?.type === "Identifier"
    && update.left.name === varName
    && (update.operator === "+=" || update.operator === "-=")) {
    const rhs = emitExpr(update.right, path, diags, ctx);
    if (rhs === null) return null;
    updateLine = `${varName} ${update.operator} ${rhs};`;
  } else {
    return null;
  }
  const bodyLines = emitStatement(stmt.body, ctx);
  if (bodyLines === null) return null;
  const indentBlock = (lines) => lines.map((l) => (l === "" ? "" : INDENT + l));
  return [
    `${varName}: int = ${initVal};`,
    `while ${testText} {`,
    ...indentBlock(bodyLines),
    ...indentBlock([updateLine]),
    "}",
  ];
}

function parseClassField(member, path, diags, classCtx) {
  if (member.static) return null;
  const name = member.key?.name;
  if (!name || member.computed) {
    diags.push(diag("E7205", "Unsupported class field key form", path));
    return null;
  }
  const ann = member.typeAnnotation?.typeAnnotation;
  let jacType = "any";
  if (ann) {
    jacType = tsTypeToJac(ann, path, diags);
    if (!jacType) return null;
  } else if (member.value) {
    jacType = inferExprType(member.value, path, diags) ?? "any";
  }
  if (member.optional) jacType = withOptionalJacType(jacType);
  let initText = member.optional ? " = None" : "";
  if (member.value) {
    const val = emitExpr(member.value, path, diags, classCtx);
    if (val === null) return null;
    initText = ` = ${val}`;
  }
  return `has ${name}: ${jacType}${initText};`;
}

function parseClassMethod(member, path, diags, classCtx, stmtFailOpen) {
  const kind = member.kind ?? "method";
  if (kind === "set") {
    diags.push(diag("E7205", "Class setters are not supported", path));
    return null;
  }
  const isCtor = kind === "constructor";
  const name = isCtor ? "__init__" : (member.key?.name ?? member.key?.id?.name);
  if (!name) {
    diags.push(diag("E7205", "Class method must have a simple name", path));
    return null;
  }
  if (member.generator) {
    diags.push(diag("E7205", "Generator class methods are not supported", path));
    return null;
  }
  if (isCtor && member.async) {
    diags.push(diag("E7205", "Async class constructors are not supported", path));
    return null;
  }
  if (kind === "get" && (member.params ?? []).length !== 0) {
    diags.push(diag("E7205", "Class getters cannot declare parameters", path));
    return null;
  }
  const jacParams = parseClassMethodParams(member.params ?? [], path, diags, classCtx);
  if (jacParams === null) return null;
  let retType = "None";
  if (member.async) {
    // A TS async method returns Promise<T>, while Jac annotates the awaited
    // value. Interop awaits are checker-Unknown, so use the same sound boundary
    // as top-level async helpers instead of claiming an unverifiable T.
    retType = "any";
  } else if (!isCtor) {
    if (member.returnType?.typeAnnotation) {
      retType = tsTypeToJac(member.returnType.typeAnnotation, path, diags);
      if (!retType) return null;
    } else {
      retType = inferReturnTypeFromBody(member.body, path, diags) ?? "any";
    }
  }
  const ctx = {
    path,
    diags,
    inClass: true,
    className: classCtx.className,
    getterNames: classCtx.getterNames,
    staticHoists: classCtx.staticHoists,
    dictBindings: new Set(),
    dictListBindings: new Set(),
    dictListFieldTypes: new Map(),
    dictFieldTypes: new Map(),
    allowReturn: true,
    failOpen: stmtFailOpen,
    droppedStatements: classCtx.droppedStatements ?? [],
    floatLocals: collectFloatLocals(member.body),
  };
  const bodyLines = [];
  const body = member.body;
  if (body?.type === "BlockStatement") {
    if (stmtFailOpen) {
      const lines = emitBlockFailOpen(body.body ?? [], ctx);
      if (lines === null) return null;
      bodyLines.push(...lines);
    } else {
      for (const s of body.body ?? []) {
        const lines = emitStatement(s, ctx);
        if (lines === null) return null;
        bodyLines.push(...lines);
      }
    }
  } else if (body) {
    const val = emitExpr(body, path, diags, ctx);
    if (val === null) return null;
    bodyLines.push(`return ${val};`);
  }
  const overrideKw = !isCtor && classCtx.baseName ? "override " : "";
  const paramText = jacParams.length ? `(${jacParams.join(", ")})` : "()";
  const asyncKw = member.async ? "async " : "";
  const lines = [`${asyncKw}${overrideKw}def ${name}${paramText} -> ${retType} {`];
  for (const l of bodyLines) lines.push(`    ${l}`);
  lines.push("}");
  return lines.join("\n");
}

function parseClass(decl, exported, path, diags, typeAliases, stmtFailOpen) {
  if (decl?.type !== "ClassDeclaration") {
    diags.push(diag("E7205", `Unsupported declaration: ${decl?.type}`, path));
    return null;
  }
  if (decl.abstract) {
    diags.push(diag("E7205", "Abstract classes are not supported", path));
    return null;
  }
  if ((decl.decorators ?? []).length) {
    diags.push(diag("E7205", "Decorated classes are not supported", path));
    return null;
  }
  const name = decl.id?.name;
  if (!name) {
    diags.push(diag("E7205", "Class must have a simple name", path));
    return null;
  }
  const baseName = parseClassExtends(decl.superClass, path, diags);
  if (diags.length) return null;
  const staticHoists = new Set();
  const preamble = [];
  for (const member of decl.body?.body ?? []) {
    if (!isClassFieldMember(member) || !member.static) continue;
    if (!isStaticLiteralInit(member.value)) {
      diags.push(diag("E7205", "Only static literal fields can be lowered (hoist or drop)", path));
      return null;
    }
    const fieldName = member.key?.name;
    if (!fieldName || member.computed) {
      diags.push(diag("E7205", "Unsupported static class field key form", path));
      return null;
    }
    const val = emitExpr(member.value, path, diags);
    if (val === null) return null;
    const pub = exported ? ":pub" : "";
    preamble.push(`glob${pub} ${fieldName} = ${val};`);
    staticHoists.add(fieldName);
  }
  const classCtx = {
    path,
    diags,
    inClass: true,
    className: name,
    baseName,
    staticHoists,
    getterNames: new Set((decl.body?.body ?? [])
      .filter((member) => isClassMethodMember(member))
      .map(normalizeClassMethodMember)
      .filter((member) => member.kind === "get" && !member.computed)
      .map((member) => member.key?.name ?? member.key?.id?.name)
      .filter(Boolean)),
    droppedStatements: [],
  };
  const fieldLines = [];
  const methodMembers = [];
  const classHoleLines = [];
  for (const member of decl.body?.body ?? []) {
    if (isClassFieldMember(member) && member.static) {
      if (member.key?.name && staticHoists.has(member.key.name)) continue;
    }
    if (isClassFieldMember(member) && !member.static) {
      const localDiags = [];
      const line = parseClassField(member, path, localDiags, classCtx);
      if (!line || localDiags.length) {
        if (stmtFailOpen) {
          if (HOLE_CTX.emitHoles) {
            classHoleLines.push(...holeCommentLines(
              member,
              localDiags[0]?.code ?? "E7205",
              localDiags[0]?.message ?? "Class field produced no output",
            ));
          }
          continue;
        }
        diags.push(...(localDiags.length ? localDiags : [diag("E7205", "Class field produced no output", path)]));
        return null;
      }
      fieldLines.push({ line, hasDefault: Boolean(member.value) });
      continue;
    }
    if (isClassMethodMember(member)) {
      methodMembers.push(member);
      continue;
    }
    if (stmtFailOpen) {
      if (HOLE_CTX.emitHoles) {
        classHoleLines.push(...holeCommentLines(
          member,
          "E7205",
          `Unsupported class member: ${member?.type}`,
        ));
      }
      continue;
    }
    diags.push(diag("E7205", `Unsupported class member: ${member?.type}`, path));
    return null;
  }
  const memberLines = [];
  const syntheticFieldLines = [];
  // V2.12: synthesize `has X: any;` stubs for `this.X` accesses the class
  // never declares — inherited-from-interop-base members (EventEmitter.emit)
  // and method-introduced state. Without the stub `self.X` is E1030 and the
  // file sinks. Stub fields are required (no default) so they sort first.
  {
    const declared = new Set();
    for (const f of fieldLines) {
      const m = /^has ([A-Za-z_$][A-Za-z0-9_$]*):/.exec(f.line);
      if (m) declared.add(m[1]);
    }
    for (const member of decl.body?.body ?? []) {
      if (isClassMethodMember(member) && member.key?.name) declared.add(member.key.name);
    }
    const stubbed = new Set();
    const seenSelf = new Set();
    const walkSelf = (n, parent = null) => {
      if (!n || typeof n !== "object" || seenSelf.has(n)) return;
      seenSelf.add(n);
      if (Array.isArray(n)) { for (const x of n) walkSelf(x, parent); return; }
      if (
        (n.type === "MemberExpression" || n.type === "OptionalMemberExpression")
        && !n.computed
        && ((n.object?.type === "ThisExpression")
          || (n.object?.type === "Identifier" && n.object.name === "self"))
        && n.property?.type === "Identifier"
      ) {
        const p = n.property.name;
        // An undeclared `this.method()` on a derived class is most likely an
        // inherited method (EventEmitter.emit in pi-tui), not mutable state.
        // Do not synthesize a field that masks it.
        const inheritedCall = Boolean(
          baseName && LOCAL_CLASSES.has(baseName)
          && parent?.type === "CallExpression" && parent.callee === n
        );
        if (!inheritedCall && !declared.has(p) && !stubbed.has(p)) stubbed.add(p);
      }
      for (const k of Object.keys(n)) {
        if (k === "type" || k === "loc" || k === "range" || k === "start" || k === "end"
          || k.endsWith("Comments")) continue;
        const v = n[k];
        if (v && typeof v === "object") walkSelf(v, n);
      }
    };
    walkSelf(decl.body);
    for (const p of [...stubbed].sort()) syntheticFieldLines.push(`has ${p}: any = None;`);
  }
  for (const f of fieldLines.filter((f) => !f.hasDefault)) memberLines.push(f.line);
  memberLines.push(...syntheticFieldLines);
  for (const f of fieldLines.filter((f) => f.hasDefault)) memberLines.push(f.line);
  memberLines.push(...classHoleLines);
  for (const member of methodMembers) {
    const localDiags = [];
    const line = parseClassMethod(normalizeClassMethodMember(member), path, localDiags, classCtx, stmtFailOpen);
    if (!line || localDiags.length) {
      if (stmtFailOpen) {
        if (HOLE_CTX.emitHoles) {
          memberLines.push(...holeCommentLines(
            member,
            localDiags[0]?.code ?? "E7205",
            localDiags[0]?.message ?? "Class method produced no output",
          ));
        }
        continue;
      }
      diags.push(...(localDiags.length ? localDiags : [diag("E7205", "Class method produced no output", path)]));
      return null;
    }
    memberLines.push(line);
  }
  if (!memberLines.length) {
    diags.push(diag("E7200", "Class produced no members", path));
    return null;
  }
  const head = exported ? "obj:pub" : "obj";
  const extendsPart = baseName ? `(${baseName})` : "";
  // A method is represented as one multiline string. Indent every physical
  // line under the object, not just the `def` line; otherwise method bodies
  // and closing braces escape the object block in the emitted Jac.
  const indentedMembers = memberLines.flatMap((memberText) =>
    memberText.split("\n").map((line) => `    ${line}`)
  );
  const objBlock = `${head} ${name}${extendsPart} {\n${indentedMembers.join("\n")}\n}`;
  const jac = preamble.length
    ? `${preamble.join("\n")}\n\n${objBlock}`
    : objBlock;
  return {
    jac,
    mappings: [{
      rule_id: "js.class.declaration.v1",
      mapping_class: "guarded",
      target: `${head} ${name}${extendsPart}`,
    }],
    droppedStatements: classCtx.droppedStatements,
  };
}

/** V2.1: lower a non-component function/arrow to a Jac `def`/`def:pub`. Jac
 * requires typed parameters (E0052) and a return type on value-returning
 * functions (E1003), so params need TS annotations and the return type is taken
 * from the TS annotation or inferred from a literal/JSX return; otherwise the
 * helper is rejected (E7232/E7233) to stay lossless. */
function parseHelperFunction(name, params, body, returnTypeNode, exported, path, diags, isAsync = false, failOpen = false) {
  const jacParams = [];
  const paramPrelude = [];
  for (const p of params ?? []) {
    let idNode = p;
    let defaultText = null;
    if (p?.type === "AssignmentPattern") {
      idNode = p.left;
      if (idNode?.type !== "Identifier") {
        diags.push(diag("E7232", "Helper default parameters must bind a simple identifier", path));
        return null;
      }
      const d = emitExpr(p.right, path, diags);
      if (d === null) return null;
      defaultText = d;
    } else if (p?.type === "RestElement") {
      diags.push(diag("E7232", "Helper rest parameters are not supported", path));
      return null;
    } else if (p?.type === "ObjectPattern" || p?.type === "ArrayPattern") {
      // Fix 2: lower a flat destructuring param to a synthetic `any` param plus
      // per-field binds prepended to the body. Nested/rename-to-nested/rest/
      // default forms fall through to the existing fail-closed reject.
      const synth = `_jx_p${jacParams.length}`;
      const lowered = lowerFlatPattern(p, synth, true, null);
      if (lowered === null) {
        diags.push(diag("E7232", `Unsupported helper parameter form: ${p.type}`, path));
        return null;
      }
      jacParams.push(`${synth}: any`);
      paramPrelude.push(...lowered.lines);
      continue;
    } else if (p?.type !== "Identifier") {
      diags.push(diag("E7232", `Unsupported helper parameter form: ${p?.type}`, path));
      return null;
    }
    const ann = idNode.typeAnnotation?.typeAnnotation;
    // V2.12: widen an untyped JS param to `any` instead of sinking the decl —
    // matches the class-method param behavior and keeps jac check green.
    let jacType = "any";
    if (ann) {
      jacType = tsTypeToJac(ann, path, diags);
      if (!jacType) return null;
    }
    let text = `${identText(idNode.name)}: ${jacType}`;
    if (defaultText) text += ` = ${defaultText}`;
    jacParams.push(text);
  }
  let retType = null;
  if (isAsync) {
    // Fix 3: an async fn's TS return type is `Promise<T>`, but Jac's
    // `async def ... -> X` return type is the awaited T. The awaited body values
    // are almost always interop calls whose type Jac resolves as Unknown, so a
    // concrete unwrapped `T` triggers E1002 (`Cannot return <Unknown>, expected
    // T`) and fails `jac check`. Widen to `any` (consistent with Fix 1) — a
    // verifiable type beats an unverifiable one.
    retType = "any";
  } else if (returnTypeNode?.typeAnnotation) {
    retType = tsTypeToJac(returnTypeNode.typeAnnotation, path, diags);
    if (!retType) return null;
  } else {
    // No TS return annotation: infer from a literal/JSX/bare return when possible,
    // otherwise widen to `any` (a value is returned but its type is not
    // literal-inferable, e.g. `return foo()` / `return someVar`). Jac requires a
    // return type on the `def`; `any` keeps the helper rather than dropping the
    // whole declaration. Previously this path failed closed with E7233.
    retType = inferReturnTypeFromBody(body, path, diags) ?? "any";
  }
  const ctx = {
    path,
    diags,
    allowReturn: true,
    dictBindings: new Set(),
    dictListBindings: new Set(),
    dictListFieldTypes: new Map(),
    dictFieldTypes: new Map(),
    failOpen,
    droppedStatements: [],
    floatLocals: collectFloatLocals(body),
  };
  // V2.12: cast-at-sink support — untyped locals returned against a concrete
  // declared return type lower as `return (x as T);` (interop-sourced values).
  if (retType && retType !== "any" && retType !== "None" && body?.type === "BlockStatement") {
    const untypedLocals = new Set();
    const seenU = new Set();
    const walkUntyped = (n) => {
      if (!n || typeof n !== "object" || seenU.has(n)) return;
      seenU.add(n);
      if (Array.isArray(n)) { for (const x of n) walkUntyped(x); return; }
      if (n.type === "VariableDeclarator" && n.id?.type === "Identifier"
        && !n.id.typeAnnotation && n.init) untypedLocals.add(n.id.name);
      for (const k of Object.keys(n)) {
        if (k === "type" || k === "loc" || k === "range" || k === "start" || k === "end"
          || k.endsWith("Comments")) continue;
        const v = n[k];
        if (v && typeof v === "object") walkUntyped(v);
      }
    };
    walkUntyped(body);
    if (untypedLocals.size) {
      ctx.retTypeCast = retType;
      ctx.untypedLocals = untypedLocals;
    }
  }
  const bodyLines = [];
  // Destructuring-param binds run first, before the original body statements.
  bodyLines.push(...paramPrelude);
  if (body?.type === "BlockStatement") {
    if (failOpen) {
      // Statement-level fail-open: drop individual unsupported statements and
      // keep the rest of the body (or bail to a decl-level drop if the body
      // can't survive soundly — see emitBlockFailOpen).
      const lines = emitBlockFailOpen(body.body ?? [], ctx);
      if (lines === null) return null;
      bodyLines.push(...lines);
    } else {
      for (const s of body.body ?? []) {
        const lines = emitStatement(s, ctx);
        if (lines === null) return null;
        bodyLines.push(...lines);
      }
    }
  } else if (body) {
    const val = emitExpr(body, path, diags);
    if (val === null) return null;
    bodyLines.push(`return ${val};`);
  }
  const pubKw = exported === false ? "" : ":pub";
  const asyncKw = isAsync ? "async " : "";
  const paramText = jacParams.length ? `(${jacParams.join(", ")})` : "()";
  const lines = [`${asyncKw}def${pubKw} ${name}${paramText} -> ${retType} {`];
  for (const l of bodyLines) lines.push(`    ${l}`);
  lines.push("}");
  const jac = `${lines.join("\n")}\n`;
  const mappings = [
    { rule_id: "js.function.declaration.v2", mapping_class: "guarded", target: `def${pubKw} ${name}` },
  ];
  return { jac, mappings, droppedStatements: ctx.droppedStatements };
}

/** Preserve an ambient TypeScript function as a typed Jac declaration.  These
 * signatures have no JS body to emit, but erasing a referenced declaration
 * leaves its calls unresolved during `jac check`. */
function parseDeclareFunction(decl, exported, path, diags) {
  const name = decl.id?.name;
  if (!name) {
    diags.push(diag("E7205", "Declared function must have a simple name", path));
    return null;
  }
  const jacParams = [];
  for (const param of decl.params ?? []) {
    if (param?.type !== "Identifier") {
      diags.push(diag("E7232", `Unsupported declared-function parameter form: ${param?.type}`, path));
      return null;
    }
    const ann = param.typeAnnotation?.typeAnnotation;
    const jacType = ann ? tsTypeToJac(ann, path, diags) : "any";
    if (!jacType) return null;
    jacParams.push(`${identText(param.name)}: ${jacType}`);
  }
  const returnAnn = decl.returnType?.typeAnnotation;
  const retType = returnAnn ? tsTypeToJac(returnAnn, path, diags) : "any";
  if (!retType) return null;
  const pubKw = exported ? ":pub" : "";
  // Jac's canonical zero-parameter declaration omits parentheses. Besides
  // avoiding W3005, this keeps source-level call counting meaningful in
  // single-evaluation regression tests.
  const paramText = jacParams.length ? `(${jacParams.join(", ")})` : "";
  return {
    jac: `def${pubKw} ${identText(name)}${paramText} -> ${retType};\n`,
    mappings: [{
      rule_id: "js.function.declaration.v2",
      mapping_class: "guarded",
      target: `def${pubKw} ${identText(name)}`,
    }],
    droppedStatements: [],
  };
}

function parseFunction(decl, exported, path, diags, hookBindings, importState, typeAliases, failOpen = false) {
  if (decl?.type !== "FunctionDeclaration") {
    diags.push(diag("E7205", `Unsupported declaration: ${decl?.type}`, path));
    return null;
  }
  // Fix 3: generators stay fail-closed (no Jac lowering). `async` is allowed on
  // top-level helpers and emits `async def` + `await` (see parseHelperFunction).
  if (decl.generator) {
    diags.push(diag("E7205", "Generator functions are not supported", path));
    return null;
  }
  const name = decl.id?.name;
  if (!name) {
    diags.push(diag("E7205", "Function must have a simple name", path));
    return null;
  }
  // V2.1: component vs helper dispatch.
  if (bodyReturnsJsx(decl.body)) {
    // Async components (React Server Components) return a Promise of JSX; the
    // component emitter has no async form, so keep them fail-closed.
    if (decl.async) {
      diags.push(diag("E7205", "Async components are not supported", path));
      return null;
    }
    // Non-exported (local) components: under fail-open, emit as a private
    // `def NAME -> JsxElement` (emitComponent already handles exported===false)
    // instead of dropping — this also un-drops helpers/components that reference
    // them by name. Strict mode keeps the original reject.
    if (!exported && !failOpen) {
      diags.push(diag("E7205", "Components must be exported (use export function or export const)", path));
      return null;
    }
    const sig = parseComponentParam(decl.params ?? [], path, diags, null, typeAliases, failOpen);
    if (!sig) return null;
    if (sig.bagName) {
      rewritePropsAccess(decl.body, sig.bagName, sig.propNames, path, diags, hookBindings);
      if (diags.length) return null;
    }
    const comp = parseComponentBody(decl.body, path, diags, hookBindings, propContextFromSig(sig), importState);
    if (!comp) return null;
    return emitComponent(name, sig, comp, exported);
  }
  return parseHelperFunction(name, decl.params, decl.body, decl.returnType, exported, path, diags, decl.async, failOpen);
}

// Strip TS value-position wrappers (`x as const`, `<T>x`, `x satisfies T`).
function unwrapTsValue(node) {
  let n = node;
  while (n && (n.type === "TSAsExpression" || n.type === "TSSatisfiesExpression" || n.type === "TSTypeAssertion")) {
    n = n.expression;
  }
  return n;
}

// Compact, bounded shape key for an unsupported `export const` initializer, used
// only to sub-cluster the dominant E7205 wall in diagnostics: for calls, the
// callee's root name (`createContext`, `styled`, `configureStore`, ...); for
// tagged templates, the tag root (`styled`); otherwise the AST node type. Lets a
// wall probe rank *which* impure-init form to model next without changing which
// declarations convert.
function initShape(node) {
  const n = unwrapTsValue(node);
  if (!n) return "none";
  const root = (e) => {
    let c = e;
    while (c) {
      if (c.type === "Identifier") return c.name;
      if (c.type === "MemberExpression") { c = c.object; continue; }
      if (c.type === "CallExpression") { c = c.callee; continue; }
      return c.type;
    }
    return "unknown";
  };
  if (n.type === "CallExpression") return `call:${root(n.callee)}`;
  if (n.type === "TaggedTemplateExpression") return `tagged:${root(n.tag)}`;
  if (n.type === "NewExpression") return `new:${root(n.callee)}`;
  return n.type;
}

// Structural gate for a top-level value `const` that may lower to a module global.
// Accepts literals, literal arithmetic, and config-shaped trees of identifiers /
// member access / arrays / objects — but never calls, tagged templates, or
// functions (CSS-in-JS factories, `createContext()`, etc.). Soundness for refs to
// other bindings relies on Piece G/H transitive-drop: if a referenced name is
// skipped or dropped upstream, the global that mentions it is dropped too.
function isModuleGlobalInit(node) {
  const n = unwrapTsValue(node);
  if (!n) return false;
  switch (n.type) {
    // V2.14: preserve a bounded pure factory call as an interop global. This is
    // intentionally limited to a stable identifier/member callee and value-only
    // arguments: no optional calls, spread, inline callbacks, or nested effects.
    // The imported factory remains an explicit interop boundary in emitted Jac.
    case "CallExpression":
      return !n.optional
        && isStableRepeatableExpr(n.callee)
        && (n.arguments ?? []).every(
          (arg) => arg?.type !== "SpreadElement" && isModuleGlobalInit(arg),
        );
    case "TaggedTemplateExpression":
    case "ArrowFunctionExpression":
    case "FunctionExpression":
      // Creating a function value is pure; its body executes only when called.
      return !n.async && !n.generator;
    case "ClassExpression":
      return false;
    // V2.16: collection constructors with zero/one pure iterable argument.
    case "NewExpression":
      if (n.callee?.type === "MemberExpression") {
        return !n.callee.optional && isStableRepeatableExpr(n.callee)
          && (n.arguments ?? []).every(
            (arg) => arg?.type !== "SpreadElement" && isModuleGlobalInit(arg),
          );
      }
      if (n.callee?.type !== "Identifier") return false;
      if (n.callee.name === "Map" && (n.arguments ?? []).length <= 1) {
        return (n.arguments ?? []).length === 0 || isModuleGlobalInit(n.arguments[0]);
      }
      if (n.callee.name === "Set" && (n.arguments ?? []).length <= 1) {
        return (n.arguments ?? []).length === 0 || isModuleGlobalInit(n.arguments[0]);
      }
      // A locally-declared class lowers to a call construction — sound at
      // module scope because the archetype is defined in this file.
      if (LOCAL_CLASSES.has(n.callee.name)) return true;
      return (n.arguments ?? []).every(
        (arg) => arg?.type !== "SpreadElement" && isModuleGlobalInit(arg),
      );
    // The vendored parser emits ESTree `Literal`; keep the Babel-specific names
    // too since the rest of the bridge accepts both forms defensively.
    case "Literal":
      // V2.12: regex literals lower to `compile(...)` (re interop) — sound as a
      // module global. Note: `\p{...}` property escapes exceed stdlib `re`
      // (runtime divergence, recorded in the mapping note).
      if (n.regex !== undefined) return true;
      return typeof n.value === "string" || typeof n.value === "number"
        || typeof n.value === "boolean" || typeof n.value === "bigint" || n.value === null;
    case "StringLiteral":
    case "NumericLiteral":
    case "BooleanLiteral":
    case "NullLiteral":
    case "BigIntLiteral":
      return true;
    case "TemplateLiteral":
      return (n.expressions ?? []).every(isModuleGlobalInit);
    case "UnaryExpression":
      return UNARY_OPS[n.operator] !== undefined && isModuleGlobalInit(n.argument);
    case "BinaryExpression":
      return BINARY_OPS[n.operator] !== undefined
        && isModuleGlobalInit(n.left) && isModuleGlobalInit(n.right);
    case "LogicalExpression":
      return LOGICAL_OPS[n.operator] !== undefined
        && isModuleGlobalInit(n.left) && isModuleGlobalInit(n.right);
    case "Identifier":
      return true;
    case "MetaProperty":
      return n.meta?.name === "import" && n.property?.name === "meta";
    case "MemberExpression":
      if (!isModuleGlobalInit(n.object)) return false;
      if (n.computed) return isModuleGlobalInit(n.property);
      return true;
    case "ArrayExpression":
      return (n.elements ?? []).every((e) => e === null || (e.type !== "SpreadElement" && isModuleGlobalInit(e)));
    case "ObjectExpression":
      // Fix 5: computed keys are sound to lower when the key expression is itself
      // a pure value init (enum member ref `[SummaryKeys.X]`, identifier, literal);
      // transitive-drop covers the case where the referenced enum was skipped.
      return (n.properties ?? []).every(
        (p) => (p.type === "Property" || p.type === "ObjectProperty")
          && (!p.computed || isModuleGlobalInit(p.key))
          && (p.kind === undefined || p.kind === "init")
          && isModuleGlobalInit(p.value),
      );
    default:
      return false;
  }
}

// A top-level value `const` that is not a component/helper lowers to a Jac module
// global instead of failing the whole file. Exported bindings become `glob:pub` so
// a same-module `def:pub` component can reference them; private ones stay `glob`.
// Factory calls / CSS-in-JS stay rejected by `isModuleGlobalInit`; config objects
// and aliases that reference imports or sibling consts pass the gate and rely on
// `emitExpr` + transitive-drop for soundness.
function parseModuleGlobal(declarator, kind, exported, path) {
  if (kind !== "const" && kind !== "let") return null;
  if (declarator?.id?.type !== "Identifier") return null;
  if ((declarator.init === null || declarator.init === undefined) && kind === "let") {
    const probe = [];
    const ann = declarator.id.typeAnnotation?.typeAnnotation;
    const jacType = ann ? tsTypeToJac(ann, path, probe) : "any";
    if (!jacType || probe.length) return null;
    const name = declarator.id.name;
    const head = exported ? "glob:pub" : "glob";
    return {
      jac: `${head} ${name}: ${jacType} = None;`,
      mappings: [{
        rule_id: "js.module.const-global.v1",
        mapping_class: "guarded",
        target: `${head} ${name} (uninitialized let -> None)`,
      }],
    };
  }
  const init = unwrapTsValue(declarator.init);
  if (!isModuleGlobalInit(init)) return null;
  const probe = [];
  const val = emitExpr(init, path, probe, { path, diags: probe });
  if (val === null || probe.length) return null;
  const ann = declarator.id.typeAnnotation?.typeAnnotation;
  let typed = "";
  if (ann) {
    const jacType = tsTypeToJac(ann, path, probe);
    if (!jacType || probe.length) return null;
    typed = `: ${jacType}`;
  } else if (
    init?.type === "NewExpression"
    && (init.callee?.type === "MemberExpression" || (
      init.callee?.type === "Identifier"
      && !LOCAL_CLASSES.has(init.callee.name)
      && init.callee.name !== "Map" && init.callee.name !== "Set"
    ))
  ) {
    // Imported constructors have no local Jac type declaration. Mark the
    // boundary explicitly so downstream interop method calls do not become
    // hard checker errors on an inferred Unknown value.
    typed = ": any";
  }
  const name = declarator.id.name;
  const head = exported ? "glob:pub" : "glob";
  return {
    jac: `${head} ${name}${typed} = ${val};`,
    mappings: [{
      rule_id: "js.module.const-global.v1",
      mapping_class: "guarded",
      target: `${head} ${name}`,
    }],
  };
}

// Fix 5: a top-level `enum`/`export enum` lowers to a Jac `enum`. Member names
// must be identifiers (string-literal computed members can't be Jac enum names);
// an explicit initializer emits `Name = value`, a bare member auto-assigns like
// TS. Non-emittable initializers or non-identifier names fail-close the enum.
function parseEnum(decl, exported, path, diags) {
  if (decl?.id?.type !== "Identifier") {
    diags.push(diag("E7205", "Enum must bind a simple identifier", path));
    return null;
  }
  const name = decl.id.name;
  const lines = [];
  for (const m of decl.members ?? []) {
    if (m.id?.type !== "Identifier") {
      diags.push(diag("E7205", `Enum member must be a simple identifier (got ${m.id?.type})`, path));
      return null;
    }
    if (m.initializer) {
      const probe = [];
      const val = emitExpr(m.initializer, path, probe, { path, diags: probe });
      if (val === null || probe.length) {
        diags.push(diag("E7205", `Enum member '${m.id.name}' has an unsupported initializer`, path));
        return null;
      }
      lines.push(`    ${m.id.name} = ${val}`);
    } else {
      lines.push(`    ${m.id.name}`);
    }
  }
  const head = exported ? "enum:pub" : "enum";
  const jac = lines.length
    ? `${head} ${name} {\n${lines.join(",\n")}\n}`
    : `${head} ${name} {}`;
  return {
    jac,
    mappings: [{
      rule_id: "js.module.enum.v1",
      mapping_class: "guarded",
      target: `${head} ${name}`,
    }],
  };
}

function parseArrowComponent(decl, exported, path, diags, hookBindings, importState, typeAliases, failOpen = false) {
  if (decl?.type !== "VariableDeclaration") {
    diags.push(diag("E7205", `Unsupported declaration: ${decl?.type}`, path));
    return null;
  }
  // V2.12: `let`/`var` module bindings are mutable module state (never a
  // component/hook), so route straight to the module-global path instead of
  // the const gate. Single declarator, matching the const path's shape.
  if (decl.kind !== "const") {
    const declarators = decl.declarations ?? [];
    if (declarators.length === 1) {
      const glob = parseModuleGlobal(declarators[0], decl.kind, exported, path);
      if (glob) return glob;
    }
    diags.push(diag("E7205", "Top-level let/var must bind a plain value (module global)", path));
    return null;
  }
  const declarators = decl.declarations ?? [];
  if (declarators.length !== 1) {
    diags.push(diag("E7205", "Supports one declarator per export const", path));
    return null;
  }
  const declarator = declarators[0];
  if (declarator.id?.type !== "Identifier") {
    diags.push(diag("E7205", "Arrow component must bind a simple identifier", path));
    return null;
  }
  const init = declarator.init;
  const fcUnwrap = unwrapFcPropsType(declarator.id?.typeAnnotation, path, diags);
  if (diags.length) return null;
  const memoUnwrap = unwrapMemoCall(init, path, diags, hookBindings);
  if (diags.length) return null;
  const innerInit = memoUnwrap.isMemo ? memoUnwrap.inner : init;
  const fwdUnwrap = innerInit?.type === "CallExpression"
    ? unwrapForwardRefCall(innerInit, path, diags, hookBindings)
    : { isForwardRef: false };
  if (diags.length) return null;
  let callback = null;
  let externalPropsType = null;
  if (memoUnwrap.isMemo && memoUnwrap.propsType) externalPropsType = memoUnwrap.propsType;
  if (fcUnwrap.propsType) externalPropsType = fcUnwrap.propsType;
  if (fwdUnwrap.isForwardRef) {
    callback = fwdUnwrap.callback;
    if (fwdUnwrap.propsType) externalPropsType = fwdUnwrap.propsType;
  } else if (innerInit?.type === "ArrowFunctionExpression") {
    callback = innerInit;
  } else {
    // Not a component/hook shape. A plain value initializer (not a mis-shaped
    // memo/FC wrapper) lowers to a module global rather than sinking the file.
    if (!memoUnwrap.isMemo && !fcUnwrap.isFc) {
      const glob = parseModuleGlobal(declarator, decl.kind, exported, path);
      if (glob) return glob;
    }
    diags.push(diag("E7205", `export const must initialize to an arrow function, forwardRef call, or memo(...) call [init=${initShape(init)}]`, path));
    return null;
  }
  // Fix 3: generators stay fail-closed; `async` is allowed on plain arrow
  // helpers (the async server-route / data-fetch case) and emits `async def`.
  if (callback.generator) {
    diags.push(diag("E7205", "Generator arrow functions are not supported", path));
    return null;
  }
  // V2.1: a plain (unwrapped) arrow that does not return JSX lowers as a helper.
  const isWrapped = fcUnwrap.isFc || memoUnwrap.isMemo || fwdUnwrap.isForwardRef;
  if (!isWrapped && !bodyReturnsJsx(callback.body)) {
    return parseHelperFunction(declarator.id.name, callback.params, callback.body, callback.returnType, exported, path, diags, callback.async, failOpen);
  }
  // Async wrapped/JSX-returning arrows are React Server Components; the component
  // emitter has no async form, so keep them fail-closed.
  if (callback.async) {
    diags.push(diag("E7205", "Async components are not supported", path));
    return null;
  }
  // Non-exported (local) arrow components: fail-open emits a private component
  // def; strict keeps the reject.
  if (!exported && !failOpen) {
    diags.push(diag("E7205", "Components must be exported (use export function or export const)", path));
    return null;
  }
  if (fcUnwrap.isFc && !fwdUnwrap.isForwardRef) {
    const param = callback.params?.[0];
    const hasPropsSource = fcUnwrap.propsType
      || (memoUnwrap.isMemo && memoUnwrap.propsType)
      || paramHasInlineType(param);
    if (!hasPropsSource) {
      diags.push(diag("E7201", "React.FC without a type argument requires an inline props annotation", path));
      return null;
    }
  }
  let sig;
  if (fwdUnwrap.isForwardRef) {
    sig = parseForwardRefParams(
      callback.params ?? [],
      path,
      diags,
      externalPropsType,
      fwdUnwrap.refElementType,
      typeAliases,
      failOpen,
    );
    if (!sig) return null;
    sig.forwardRefUnwrapped = true;
  } else {
    sig = parseComponentParam(callback.params ?? [], path, diags, externalPropsType, typeAliases, failOpen);
    if (!sig) return null;
    if (fcUnwrap.isFc) sig.fcUnwrapped = true;
  }
  if (memoUnwrap.isMemo) sig.memoUnwrapped = true;
  if (sig.bagName) {
    rewritePropsAccess(callback.body, sig.bagName, sig.propNames, path, diags, hookBindings);
    if (diags.length) return null;
  }
  const comp = parseComponentBody(callback.body, path, diags, hookBindings, propContextFromSig(sig), importState);
  if (!comp) return null;
  return emitComponent(declarator.id.name, sig, comp, exported);
}

function summarize(mappings) {
  const summary = { exact: 0, guarded: 0, interop: 0, rejected: 0, proposed: 0 };
  for (const m of mappings) {
    const cls = m.mapping_class;
    if (cls === "exact") summary.exact += 1;
    else if (cls === "guarded") summary.guarded += 1;
    else if (cls === "interop") summary.interop += 1;
    else if (cls === "rejected") summary.rejected += 1;
    else if (cls === "proposed") summary.proposed += 1;
  }
  return summary;
}

/** Fail closed when bridge stamps a rule_id absent from the versioned catalog. */
function validateMappings(mappings, path, diags) {
  for (const m of mappings) {
    const rule = RULE_BY_ID.get(m.rule_id);
    if (!rule) {
      diags.push(diag("E7105", `Unknown mapping rule_id: ${m.rule_id}`, path));
      continue;
    }
    if (!rule.enabled) {
      diags.push(diag("E7105", `Disabled mapping rule referenced: ${m.rule_id}`, path));
      continue;
    }
    if (rule.mapping_class !== m.mapping_class) {
      diags.push(
        diag(
          "E7105",
          `Mapping class mismatch for ${m.rule_id}: catalog=${rule.mapping_class} entry=${m.mapping_class}`,
          path,
        ),
      );
    }
  }
}

function convertEnvelope(payload) {
  const diags = [];
  const path = payload.path ?? "";
  // Fail-open per declaration: degrade an unsupported top-level declaration to a
  // recorded skip and emit the rest, instead of sinking the whole file. Gated
  // (default off) so strict mode — and every existing test — is byte-identical.
  const failOpen = payload.failOpen === true;
  // Statement-level fail-open (helpers only): drop an unsupported statement and
  // keep the rest of the declaration. Defaults to the decl-level failOpen but can
  // be toggled independently (probing / A-B). Inert unless failOpen is on.
  // Env override lets a probe force the statement-level path off across the whole
  // subprocess pipeline (harvest/project convert) for a clean A-B, without a
  // payload change. `JS2JAC_STMT_FAILOPEN=0` disables it.
  const stmtEnvOff = typeof process !== "undefined" && process.env
    && process.env.JS2JAC_STMT_FAILOPEN === "0";
  const stmtFailOpen = failOpen && payload.stmtFailOpen !== false && !stmtEnvOff;
  // Cross-file dropped-export propagation: local import names an upstream module
  // dropped (fail-open) in a prior conversion. Seed them into the reference-safe
  // drop so any declaration here that uses one is dropped too, and prune them
  // from the emitted import lines. Empty (and inert) unless project mode passes
  // them, so strict/standalone conversion is byte-identical.
  const externalDropped = Array.isArray(payload.externalDropped)
    ? new Set(payload.externalDropped)
    : new Set();
  // LLM-cleanup hole mode: emit the original JS of every dropped statement/decl
  // as a `# JS2JAC-HOLE` comment instead of silently discarding it. Needs the
  // original module `source` to slice node ranges. Default off; only meaningful
  // with failOpen (there is nothing to salvage in strict). Set the module-scoped
  // HOLE_CTX here (per-file reset, mirroring REACT_NAMESPACE_LOCALS).
  const emitHoles = payload.emitHoles === true && failOpen;
  HOLE_CTX = { emitHoles, source: typeof payload.source === "string" ? payload.source : null };
  // V2.12: per-file reset of the regex-interop flag (mirrors HOLE_CTX).
  REGEX_INTEROP = { compile: false, search: false, split: false, sub: false, flags: new Set() };
  PROCESS_ENV_INTEROP = false;
  AMBIENT_INTEROP_GLOBALS = new Set();
  IDENT_RENAMES = new Map();
  MATCH_LOCALS = new Set();
  if (payload.protocolVersion !== PROTOCOL_VERSION) {
    return { ok: false, diagnostics: [diag("E7101", "Unsupported protocol version", path)] };
  }
  const ast = payload.ast;
  if (ast?.type !== "File") {
    return { ok: false, diagnostics: [diag("E7200", `Unexpected AST root: ${ast?.type}`, path)] };
  }
  const body = ast.program?.body ?? [];
  if (!body.length) {
    return { ok: false, diagnostics: [diag("E7200", "Empty module is not supported", path)] };
  }
  SOURCE_BOUND_NAMES = collectBoundNames(body);
  EXPR_TEMP_INDEX = 0;
  // V2.12: reserved-name local renames + Match-shape local tracking (per file).
  const { renames: localRenames, matchLocals } = collectLocalRenames(body);
  IDENT_RENAMES = localRenames;
  MATCH_LOCALS = matchLocals;
  DICT_RETURNING_FUNCS = new Set();
  DICT_RETURN_FIELD_TYPES = new Map();
  MODULE_MAP_BINDINGS = new Set();
  NUMBER_RETURNING_FUNCS = new Set();
  LOCAL_CLASSES = new Set();
  for (const item of body) {
    const declaration = item?.type === "ExportNamedDeclaration" ? item.declaration : item;
    if (declaration?.type === "ClassDeclaration" && declaration.id?.type === "Identifier") {
      LOCAL_CLASSES.add(declaration.id.name);
    }
    if (declaration?.type === "FunctionDeclaration" && declaration.id?.name
      && declaration.returnType?.typeAnnotation?.type === "TSNumberKeyword") {
      NUMBER_RETURNING_FUNCS.add(declaration.id.name);
    }
    if (declaration?.type === "VariableDeclaration") {
      for (const declarator of declaration.declarations ?? []) {
        const init = declarator.init;
        if (declarator.id?.type === "Identifier"
          && (init?.type === "ArrowFunctionExpression" || init?.type === "FunctionExpression")
          && init.returnType?.typeAnnotation?.type === "TSNumberKeyword") {
          NUMBER_RETURNING_FUNCS.add(declarator.id.name);
        }
      }
    }
  }
  const typeAliases = collectTypeAliases(body);
  // V2.12: collect functions whose TS return annotation is an object type —
  // their call results are dict values, so member access lowers to subscripts.
  {
    const recordNode = (ann, depth = 0) => {
      if (!ann || depth > 6) return null;
      if (ann.type === "TSTypeLiteral") return ann;
      if (ann.type === "TSParenthesizedType") return recordNode(ann.typeAnnotation, depth + 1);
      // `T | None` returns are still dict-shaped (callers null-guard).
      if (ann.type === "TSUnionType") {
        for (const type of ann.types ?? []) {
          const resolved = recordNode(type, depth + 1);
          if (resolved) return resolved;
        }
        return null;
      }
      if (ann.type === "TSTypeReference" && ann.typeName?.type === "Identifier") {
        const e = typeAliases.get(ann.typeName.name);
        if (!e) return null;
        if (e.kind === "interface") return e.node?.body ?? e.node;
        return recordNode(e.node, depth + 1);
      }
      return null;
    };
    const noteRecordReturn = (name, ann) => {
      const record = recordNode(ann);
      if (!record) return;
      DICT_RETURNING_FUNCS.add(name);
      const fields = new Map();
      for (const member of record.members ?? record.body ?? []) {
        if (member.type !== "TSPropertySignature" || member.key?.type !== "Identifier") continue;
        const probe = [];
        const fieldType = tsTypeToJac(member.typeAnnotation?.typeAnnotation, path, probe);
        if (fieldType && !probe.length) {
          fields.set(member.key.name, member.optional ? withOptionalJacType(fieldType) : fieldType);
        }
      }
      DICT_RETURN_FIELD_TYPES.set(name, fields);
    };
    const seenWalk = new Set();
    const walkReturns = (n) => {
      if (!n || typeof n !== "object" || seenWalk.has(n)) return;
      seenWalk.add(n);
      if (Array.isArray(n)) { for (const x of n) walkReturns(x); return; }
      if (n.type === "FunctionDeclaration" && n.id?.name) {
        noteRecordReturn(n.id.name, n.returnType?.typeAnnotation);
      }
      if (n.type === "VariableDeclarator" && n.id?.type === "Identifier"
        && (n.init?.type === "ArrowFunctionExpression" || n.init?.type === "FunctionExpression")) {
        noteRecordReturn(n.id.name, n.init.returnType?.typeAnnotation);
      }
      for (const k of Object.keys(n)) {
        if (k === "type" || k === "loc" || k === "range" || k === "start" || k === "end"
          || k.endsWith("Comments")) continue;
        const v = n[k];
        if (v && typeof v === "object") walkReturns(v);
      }
    };
    walkReturns(body);
  }
  // V2.12: module-level regex-const names (for `.test(x)` on them).
  REGEX_CONSTS = new Set();
  for (const item of body) {
    const decl = item?.type === "ExportNamedDeclaration" ? item.declaration : item;
    if (decl?.type !== "VariableDeclaration") continue;
    for (const d of decl.declarations ?? []) {
      if (d?.id?.type === "Identifier" && d.init?.type === "NewExpression"
        && d.init.callee?.type === "Identifier" && d.init.callee.name === "Map") {
        MODULE_MAP_BINDINGS.add(d.id.name);
      }
      if (d?.id?.type === "Identifier" && d.init?.type === "Literal" && d.init.regex) {
        REGEX_CONSTS.add(d.id.name);
      }
    }
  }
  const hookBindings = collectHookBindings(body);
  // Per-file reset: emitMemberAccess reads this to fail-close computed access on
  // a lowered-away React namespace. Assigned (not merged) so the in-process probe
  // loop never leaks state between files.
  REACT_NAMESPACE_LOCALS = hookBindings.namespaces;
  const importState = { usedLocals: new Set(), namespaceLocals: new Set() };
  const interopImports = collectInteropImports(body);
  // Pre-pass: a bare `export { A, B }` list (no `from`) marks locally-declared
  // A/B as exported, decoupling the declaration from its export statement. Only
  // identity specifiers are collected here; aliases/re-exports are diagnosed in
  // the main loop so they surface exactly once.
  const exportedNames = collectBareExportNames(body);
  // V2.8: `export default Foo` decouples the default from a local declaration
  // the same way a bare `export { Foo }` does — mark Foo public here so its
  // declaration emits as :pub when the main loop reaches it.
  for (const item of body) {
    if (item.type === "ExportDefaultDeclaration" && item.declaration?.type === "Identifier") {
      exportedNames.add(item.declaration.name);
    }
  }
  // Every name this module exports publicly, mirroring the exported-ness the
  // main loop assigns. Used to report which *dropped* declarations were public
  // (`droppedExports`) so cross-file importers can prune them.
  const publicNames = new Set(exportedNames);
  let defaultPublicName = "";
  for (const item of body) {
    if (item.type === "ExportNamedDeclaration" && item.declaration) {
      for (const n of declaredNames(item)) publicNames.add(n);
    } else if (item.type === "ExportDefaultDeclaration") {
      const d = item.declaration;
      if (d?.type === "FunctionDeclaration" && d.id?.name) {
        defaultPublicName = d.id.name;
      } else if (d?.type === "FunctionDeclaration" || d?.type === "ArrowFunctionExpression") {
        defaultPublicName = defaultExportBasename(path);
      } else if (d?.type === "Identifier") {
        defaultPublicName = d.name;
      }
      if (defaultPublicName) publicNames.add(defaultPublicName);
    }
  }
  const outputs = [];
  const droppedDirectives = [];
  const reExportLines = []; // fail-open: re-export barrel forms lowered to Jac imports
  const skips = []; // { names, code } — declarations that failed to convert (fail-open)
  const declHoles = []; // hole-mode: original JS of each skipped top-level decl
  // V2.12: module-level imperative statements (for/while/if/expr/try/…) run at
  // module load in JS; Jac's form is a `with entry { ... }` block, emitted after
  // all declarations (JS hoists functions; glob inits keep source order).
  const entryLines = [];
  const entryDrops = [];
  const MODULE_STMT_KINDS = new Set([
    "ForStatement", "ForOfStatement", "ForInStatement", "WhileStatement",
    "DoWhileStatement", "IfStatement", "ExpressionStatement", "BlockStatement",
    "TryStatement", "SwitchStatement", "ThrowStatement",
  ]);
  // Strict: any per-item failure aborts the file (populate `diags`). Fail-open:
  // record the item as a skip and keep going. Called with the diags the item
  // produced and the item itself (for its bound names). The first diag code is
  // retained per skip so project mode can cluster the dominant decl-level wall.
  const recordFailure = (localDiags, item) => {
    if (failOpen) {
      const code = localDiags[0]?.code ?? "E7205";
      const msg = localDiags[0]?.message ?? "";
      skips.push({ names: declaredNames(item), code, msg });
      if (emitHoles) declHoles.push(holeCommentLines(item, code, msg).join("\n"));
    } else {
      diags.push(...localDiags);
    }
  };
  for (const item of body) {
    if (item.type === "ImportDeclaration") continue;
    if (isSkippableTypeDeclaration(item)) continue;
    // Directive-prologue statements ('use client'/'use server'/'use strict')
    // are RSC/compiler hints with no runtime semantics we model — drop them
    // rather than sinking the file on E7205. ESTree tags only true prologue
    // directives with a `.directive` string; a mid-module `"foo";` is not
    // tagged and still falls through to the unsupported-form path.
    if (item.type === "ExpressionStatement" && typeof item.directive === "string") {
      droppedDirectives.push(item.directive);
      continue;
    }
    let exported = false;
    let decl = item;
    if (item.type === "ExportNamedDeclaration") {
      decl = item.declaration;
      if (!decl) {
        const ld = [];
        if (item.source) {
          // Fail-open: lower `export { ... } from './m'` to a Jac import; strict
          // keeps the E7205 (byte-identical). Unhandleable specifier shapes fall
          // through to the strict diagnostic in both modes.
          const lowered = failOpen ? lowerReExport(item) : null;
          if (lowered) {
            if (lowered.line) reExportLines.push(lowered.line);
            for (const n of lowered.exportedNames) publicNames.add(n);
            continue;
          }
          ld.push(diag("E7205", "Re-export forms are not supported", path));
        } else {
          for (const spec of item.specifiers ?? []) {
            if (spec.type !== "ExportSpecifier" || spec.local?.name !== spec.exported?.name) {
              ld.push(diag("E7205", "Only identity named exports (export { Name }) are supported", path));
            }
          }
        }
        if (ld.length) recordFailure(ld, item);
        continue;
      }
      exported = true;
    } else if (item.type === "ExportDefaultDeclaration") {
      // V2.8: convert the common React default-export idioms. `export default
      // Foo` was already marked public in the pre-pass, so its declaration is
      // emitted where it appears — skip the export node itself. Inline function
      // and arrow defaults are lowered under a canonical (basename) name when
      // anonymous, so cross-file importers can resolve `default as X`.
      const d = item.declaration;
      if (d?.type === "Identifier") {
        continue;
      } else if (d?.type === "FunctionDeclaration") {
        decl = d;
        if (!decl.id?.name) {
          decl.id = { type: "Identifier", name: defaultExportBasename(path) };
        }
        exported = true;
      } else if (d?.type === "ArrowFunctionExpression") {
        decl = {
          type: "VariableDeclaration",
          kind: "const",
          declarations: [{
            type: "VariableDeclarator",
            id: { type: "Identifier", name: defaultExportBasename(path) },
            init: d,
          }],
        };
        exported = true;
      } else {
        recordFailure([diag("E7205", `Unsupported default export form: ${d?.type ?? "unknown"} (use 'export default function', an arrow const, or 'export default Name')`, path)], item);
        continue;
      }
    } else if (item.type === "ExportAllDeclaration") {
      // `export * from './m'` / `export * as ns from './m'` — a whole-module
      // re-export. Fail-open lowers to a Jac wildcard import; strict keeps E7205.
      const lowered = failOpen ? lowerReExport(item) : null;
      if (lowered) {
        if (lowered.line) reExportLines.push(lowered.line);
        for (const n of lowered.exportedNames) publicNames.add(n);
        continue;
      }
      recordFailure([diag("E7205", "Re-export forms are not supported", path)], item);
      continue;
    } else if (item.type === "FunctionDeclaration" || item.type === "TSDeclareFunction" || item.type === "VariableDeclaration"
      || item.type === "TSEnumDeclaration" || item.type === "ClassDeclaration") {
      const declName = item.type === "VariableDeclaration"
        ? item.declarations?.[0]?.id?.name
        : item.id?.name;
      if (declName && exportedNames.has(declName)) exported = true;
    } else if (MODULE_STMT_KINDS.has(item.type)) {
      // Module-level statement — lower into the shared `with entry` block.
      const entryCtx = {
        path,
        diags: [],
        inClass: false,
        dictBindings: new Set(),
        dictListBindings: new Set(),
        dictListFieldTypes: new Map(),
        dictFieldTypes: new Map(),
        allowReturn: false,
        failOpen: stmtFailOpen,
        droppedStatements: entryDrops,
      };
      const lines = emitStatement(item, entryCtx);
      if (lines !== null) {
        entryLines.push(...lines);
      } else if (stmtFailOpen) {
        entryLines.push(...holeCommentLines(item, entryCtx.diags[0]?.code ?? "E7205", entryCtx.diags[0]?.message ?? ""));
      } else {
        diags.push(...entryCtx.diags);
      }
      continue;
    } else {
      recordFailure([diag("E7205", `Unsupported top-level form: ${item.type} (only function/const/class declarations are supported)`, path)], item);
      continue;
    }
    // Dispatch into a *local* diag buffer so a failure can degrade to a skip in
    // fail-open mode without corrupting the strict-mode abort contract.
    const localDiags = [];
    let out = null;
    if (decl.type === "FunctionDeclaration") {
      out = parseFunction(decl, exported, path, localDiags, hookBindings, importState, typeAliases, stmtFailOpen);
    } else if (decl.type === "TSDeclareFunction") {
      out = parseDeclareFunction(decl, exported, path, localDiags);
    } else if (decl.type === "VariableDeclaration") {
      out = parseArrowComponent(decl, exported, path, localDiags, hookBindings, importState, typeAliases, stmtFailOpen);
    } else if (decl.type === "TSEnumDeclaration") {
      out = parseEnum(decl, exported, path, localDiags);
    } else if (decl.type === "ClassDeclaration") {
      out = parseClass(decl, exported, path, localDiags, typeAliases, stmtFailOpen);
    } else {
      localDiags.push(diag("E7205", `Unsupported declaration: ${decl.type}`, path));
    }
    if (!out || localDiags.length) {
      recordFailure(localDiags.length ? localDiags : [diag("E7200", "Declaration produced no output", path)], item);
      continue;
    }
    const refs = new Set();
    collectReferencedNames(decl, refs);
    outputs.push({ ...out, names: declaredNames(item), refs });
  }
  if (diags.length) return { ok: false, diagnostics: diags };
  // Materialize the `with entry` block once module statements were collected.
  // It carries the statements' referenced names so the ref-safety fixpoint can
  // drop it (names: []) if it touches a skipped/dropped declaration.
  if (entryLines.length) {
    const entryRefs = new Set();
    for (const item of body) {
      if (MODULE_STMT_KINDS.has(item.type)) collectReferencedNames(item, entryRefs);
    }
    outputs.push({
      jac: [`with entry {`, ...entryLines.map((l) => `    ${l}`), `}`].join("\n"),
      mappings: [{
        rule_id: "js.module.entry-block.v1",
        mapping_class: "guarded",
        target: `module-level statements -> with entry (${entryLines.length} line(s))`,
      }],
      names: [],
      refs: entryRefs,
      droppedStatements: entryDrops,
    });
  }
  // A module containing only erased TypeScript surface (interfaces/type aliases
  // and type-only imports) is a successful conversion with an empty runtime
  // body, not an E7200 hard reject. Keep an explicit mapping so project reports
  // distinguish intentional erasure from an unsupported declaration drop.
  const typeOnlyModule = body.length > 0 && body.every((item) =>
    item.type === "ImportDeclaration" || isSkippableTypeDeclaration(item)
  );
  if (!outputs.length && !skips.length && !reExportLines.length && typeOnlyModule) {
    outputs.push({
      jac: "",
      mappings: [{
        rule_id: "ts.module.type-erasure.v1",
        mapping_class: "exact",
        target: "type-only module -> empty Jac runtime module",
      }],
      names: [],
      refs: new Set(),
      droppedStatements: [],
    });
  }
  // Fail-open reference safety: a kept declaration that references a name bound
  // by a skipped (or transitively dropped) declaration would dangle, so drop it
  // too. Iterate to a fixpoint over the transitive closure. Over-approximated
  // refs mean this only ever errs toward dropping — never toward an unsound keep.
  if (failOpen && (skips.length || externalDropped.size)) {
    const unsafe = new Set([...skips.flatMap((s) => s.names), ...externalDropped]);
    if (unsafe.size) {
      let changed = true;
      while (changed) {
        changed = false;
        for (const o of outputs) {
          if (o._dropped) continue;
          for (const r of o.refs) {
            if (unsafe.has(r) && !o.names.includes(r)) {
              o._dropped = true;
              for (const n of o.names) unsafe.add(n);
              changed = true;
              break;
            }
          }
        }
      }
    }
  }
  const kept = outputs.filter((o) => !o._dropped);
  const droppedDeclCount = skips.length + (outputs.length - kept.length);
  // Statement-level fail-open: tally the individual statements dropped from
  // *kept* declarations (a decl that itself got dropped subsumes its stmt drops).
  // Reported separately from decl walls so decl-level yield stays comparable.
  const stmtDrops = {};
  let stmtDropCount = 0;
  for (const o of kept) {
    for (const d of o.droppedStatements ?? []) {
      stmtDrops[d.code] = (stmtDrops[d.code] ?? 0) + 1;
      stmtDropCount += 1;
    }
  }
  // Decl-level wall histogram: which diagnostic code sank each skipped
  // declaration (transitively-dropped ones are ref-safety, not a distinct
  // wall). Reported on both success and the no-kept failure so probes see the
  // dominant blocker even for files where every declaration is unsupported.
  const skipReasons = {};
  // Sub-cluster the dominant walls by their (bounded, dynamic-token-carrying)
  // diagnostic message so probes can see *which* top-level form / declaration
  // kind sinks each declaration, not just the E7205 bucket. Normalize the
  // message to its discriminating token: keep the code prefix + the first
  // `Type`-shaped token so counts collapse across paths/names.
  const skipDetails = {};
  for (const s of skips) {
    const code = s.code ?? "E7205";
    skipReasons[code] = (skipReasons[code] ?? 0) + 1;
    const key = s.msg ? `${code} | ${s.msg}` : code;
    skipDetails[key] = (skipDetails[key] ?? 0) + 1;
  }
  const transitiveDrops = outputs.length - kept.length;
  if (transitiveDrops > 0) {
    skipReasons["transitive-drop"] = (skipReasons["transitive-drop"] ?? 0) + transitiveDrops;
  }
  if (!kept.length && !reExportLines.length) {
    return {
      ok: false,
      keptCount: 0,
      droppedCount: droppedDeclCount,
      skipReasons,
      skipDetails,
      diagnostics: [diag("E7200", "No convertible declarations found", path)],
    };
  }
  // Prune interop import specifiers bound to a name dropped upstream: those
  // bindings no longer resolve to anything. A named import pruned to empty is
  // dropped whole; a side-effect import (no specifiers) is always preserved.
  const filteredInterop = externalDropped.size
    ? interopImports.reduce((acc, imp) => {
        if (!imp.specifiers.length) { acc.push(imp); return acc; }
        const specs = imp.specifiers.filter((s) => !externalDropped.has(s.local));
        if (specs.length) acc.push({ ...imp, specifiers: specs });
        return acc;
      }, [])
    : interopImports;
  const reactImportLines = formatReactImports(body, hookBindings, importState);
  // V2.12: JS regex literals lowered via Python `re` — emit the interop import
  // only when a regex actually lowered in this file.
  const regexImportLines = (REGEX_INTEROP.compile || REGEX_INTEROP.search || REGEX_INTEROP.split || REGEX_INTEROP.sub)
    ? [`import from re { ${[...new Set([...REGEX_INTEROP.compile ? ["compile"] : [], ...REGEX_INTEROP.search ? ["search"] : [], ...REGEX_INTEROP.split ? ["split"] : [], ...REGEX_INTEROP.sub ? ["sub"] : [], ...[...REGEX_INTEROP.flags].sort()])].join(", ")} }`]
    : [];
  const osImportLines = PROCESS_ENV_INTEROP ? ["import from os { environ }"] : [];
  const importLines = [...reactImportLines, ...formatInteropImports(filteredInterop), ...reExportLines, ...regexImportLines, ...osImportLines];
  const ambientInteropLines = [...AMBIENT_INTEROP_GLOBALS]
    .sort()
    .map((name) => `glob ${name}: any = None;`);
  const bodyParts = [...ambientInteropLines, ...kept.map((o) => o.jac.trimEnd())];
  // Hole mode: append each skipped top-level decl's original JS as a trailing
  // commented block, so an LLM cleanup pass sees the whole file's intent (the
  // converted scaffold above + the unconverted holes below) without re-fetching
  // the source. Comments are inert Jac — soundness/gate outcome is unchanged.
  if (emitHoles && declHoles.length) {
    bodyParts.push(`# ===== JS2JAC UNCONVERTED (${declHoles.length} decl(s), needs LLM) =====\n${declHoles.join("\n\n")}`);
  }
  const jacBody = bodyParts.join("\n\n");
  const jac = jacBody
    ? (importLines.length ? `${importLines.join("\n")}\n\n${jacBody}\n` : `${jacBody}\n`)
    : `${importLines.join("\n")}\n`;
  const mappings = kept.flatMap((o) => o.mappings);
  for (let i = 0; i < droppedDeclCount; i += 1) {
    mappings.push({
      rule_id: "js.module.decl-skip.v1",
      mapping_class: "rejected",
      target: "skipped unsupported top-level declaration (fail-open)",
    });
  }
  for (const d of droppedDirectives) {
    mappings.push({
      rule_id: "js.module.directive-prologue.v1",
      mapping_class: "guarded",
      target: `dropped directive ${JSON.stringify(d)}`,
    });
  }
  for (const o of kept) {
    for (const d of o.droppedStatements ?? []) {
      mappings.push({
        rule_id: "js.stmt.fail-open.v1",
        mapping_class: "rejected",
        target: `dropped unsupported statement ${d.kind} (${d.code}) inside a kept declaration`,
      });
    }
  }
  for (const imp of filteredInterop) {
    mappings.push({
      rule_id: "js.import.interop.v2",
      mapping_class: "interop",
      target: `preserved import ${imp.source}`,
    });
  }
  for (const line of reExportLines) {
    mappings.push({
      rule_id: "js.module.reexport.v1",
      mapping_class: "interop",
      target: `lowered re-export -> ${line}`,
    });
  }
  // Report which dropped declarations were public exports so project mode can
  // propagate the drop to importers (cross-file reference safety).
  const droppedNames = new Set(skips.flatMap((s) => s.names));
  for (const o of outputs) {
    if (o._dropped) for (const n of o.names) droppedNames.add(n);
  }
  const droppedExports = [...droppedNames].filter((n) => publicNames.has(n));
  if (defaultPublicName && droppedNames.has(defaultPublicName) && !droppedExports.includes("default")) {
    droppedExports.push("default");
  }
  const mappingDiags = [];
  validateMappings(mappings, path, mappingDiags);
  if (mappingDiags.length) return { ok: false, diagnostics: mappingDiags };
  return {
    ok: true,
    jac,
    keptCount: kept.length,
    droppedCount: droppedDeclCount,
    reExportCount: reExportLines.length,
    stmtDrops,
    stmtDropCount,
    droppedExports,
    skipReasons,
    skipDetails,
    mappings,
    diagnostics: [],
    summary: summarize(mappings),
    ruleSetVersion: RULE_SET_VERSION,
  };
}

function main() {
  const input = readFileSync(0, "utf8");
  let payload;
  try {
    payload = JSON.parse(input);
  } catch (e) {
    process.stdout.write(
      JSON.stringify({ ok: false, diagnostics: [diag("E7101", `Invalid JSON: ${e}`)] })
    );
    process.exit(0);
  }
  const result = convertEnvelope(payload);
  process.stdout.write(JSON.stringify({ protocolVersion: PROTOCOL_VERSION, ...result }));
}

// Run as a bridge only when executed directly; importable for in-process probes.
if (import.meta.main) {
  main();
}

export { convertEnvelope, PROTOCOL_VERSION };
