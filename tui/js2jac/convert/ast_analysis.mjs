/** Pure AST binding/reference analysis used by fail-open conversion. */

export function collectPatternNames(node, out) {
  if (!node) return;
  if (node.type === "Identifier") out.push(node.name);
  else if (node.type === "ObjectPattern") {
    for (const p of node.properties ?? []) collectPatternNames(p.value ?? p.argument, out);
  } else if (node.type === "ArrayPattern") {
    for (const el of node.elements ?? []) collectPatternNames(el, out);
  } else if (node.type === "RestElement") collectPatternNames(node.argument, out);
  else if (node.type === "AssignmentPattern") collectPatternNames(node.left, out);
}

export function boundSiblingNames(stmt) {
  const out = [];
  if (stmt?.type === "VariableDeclaration") {
    for (const d of stmt.declarations ?? []) collectPatternNames(d.id, out);
  } else if (stmt?.type === "FunctionDeclaration" || stmt?.type === "ClassDeclaration") {
    if (stmt.id?.name) out.push(stmt.id.name);
  }
  return out;
}

export function containsReturn(node) {
  let found = false;
  (function walk(n) {
    if (found || !n || typeof n !== "object") return;
    if (Array.isArray(n)) { for (const x of n) walk(x); return; }
    if (n.type === "ReturnStatement") { found = true; return; }
    if (n.type === "FunctionDeclaration" || n.type === "FunctionExpression"
      || n.type === "ArrowFunctionExpression") return;
    for (const [key, value] of Object.entries(n)) {
      if (["type", "loc", "range", "start", "end"].includes(key)) continue;
      walk(value);
    }
  })(node);
  return found;
}

export function declaredNames(item) {
  let declaration = item;
  if (item.type === "ExportNamedDeclaration" || item.type === "ExportDefaultDeclaration") {
    declaration = item.declaration;
  }
  if (!declaration) return [];
  if (declaration.type === "FunctionDeclaration" || declaration.type === "ClassDeclaration"
    || declaration.type === "TSEnumDeclaration") {
    return declaration.id?.name ? [declaration.id.name] : [];
  }
  if (declaration.type === "VariableDeclaration") {
    const names = [];
    for (const declarator of declaration.declarations ?? []) {
      if (declarator.id?.type === "Identifier") names.push(declarator.id.name);
    }
    return names;
  }
  return [];
}

export function collectReferencedNames(node, out) {
  if (!node || typeof node !== "object") return;
  if (Array.isArray(node)) {
    for (const child of node) collectReferencedNames(child, out);
    return;
  }
  const type = node.type;
  if (type === "Identifier" || type === "JSXIdentifier") {
    if (typeof node.name === "string") out.add(node.name);
    return;
  }
  for (const [key, value] of Object.entries(node)) {
    if (["type", "loc", "range", "start", "end"].includes(key)) continue;
    if (type === "MemberExpression" && key === "property" && !node.computed) continue;
    if (type === "JSXMemberExpression" && key === "property") continue;
    if ((type === "Property" || type === "ObjectProperty") && key === "key" && !node.computed) continue;
    if (type === "JSXAttribute" && key === "name") continue;
    collectReferencedNames(value, out);
  }
}

/** Collect names introduced by source bindings for hygienic generated temps. */
export function collectBoundNames(node) {
  const names = new Set();
  const bindPattern = (pattern) => {
    const found = [];
    collectPatternNames(pattern, found);
    for (const name of found) names.add(name);
  };
  const walk = (value) => {
    if (!value || typeof value !== "object") return;
    if (Array.isArray(value)) { for (const child of value) walk(child); return; }
    if (value.type === "VariableDeclarator") bindPattern(value.id);
    else if (value.type === "FunctionDeclaration" || value.type === "FunctionExpression"
      || value.type === "ArrowFunctionExpression") {
      if (value.id) bindPattern(value.id);
      for (const param of value.params ?? []) bindPattern(param);
    } else if (value.type === "ClassDeclaration" && value.id) bindPattern(value.id);
    else if (value.type === "CatchClause" && value.param) bindPattern(value.param);
    else if (value.type === "ImportSpecifier" || value.type === "ImportDefaultSpecifier"
      || value.type === "ImportNamespaceSpecifier") bindPattern(value.local);
    for (const [key, child] of Object.entries(value)) {
      if (["type", "loc", "range", "start", "end"].includes(key)) continue;
      walk(child);
    }
  };
  walk(node);
  return names;
}
