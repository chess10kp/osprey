#!/usr/bin/env bun
/**
 * Hermetic @babel/parser bridge for js2jac (protocol version 1).
 * Reads a JSON request from stdin; writes a versioned JSON envelope to stdout.
 */
import { createRequire } from "module";
import { fileURLToPath } from "url";
import path from "path";

const PROTOCOL_VERSION = 1;
const __dirname = path.dirname(fileURLToPath(import.meta.url));

function loadParser() {
  const vendorRoot = path.join(__dirname, "vendor", "babel_parser");
  const req = createRequire(path.join(vendorRoot, "package.json"));
  return req("@babel/parser");
}

function pluginsForLanguage(language) {
  const plugins = ["estree"];
  if (language === "jsx" || language === "tsx") {
    plugins.push("jsx");
  }
  if (language === "ts" || language === "tsx") {
    plugins.push("typescript");
  }
  return plugins;
}

function parserVersion(parserMod) {
  try {
    return parserMod.version || "unknown";
  } catch {
    return "unknown";
  }
}

function failureEnvelope(parserName, parserVer, diagnostics) {
  return {
    protocolVersion: PROTOCOL_VERSION,
    parser: { name: parserName, version: parserVer },
    ok: false,
    diagnostics,
  };
}

async function main() {
  const input = await Bun.stdin.text();
  let request;
  try {
    request = JSON.parse(input);
  } catch {
    process.stdout.write(
      JSON.stringify(
        failureEnvelope("@babel/parser", "unknown", [
          {
            code: "E7101",
            message: "Invalid JSON request on stdin",
            reason: "invalid_request",
          },
        ])
      )
    );
    return;
  }

  if (request.protocolVersion !== PROTOCOL_VERSION) {
    process.stdout.write(
      JSON.stringify(
        failureEnvelope("@babel/parser", "unknown", [
          {
            code: "E7101",
            message: `Unsupported protocolVersion: ${request.protocolVersion}`,
            reason: "invalid_request",
          },
        ])
      )
    );
    return;
  }

  const language = String(request.language || "js").toLowerCase();
  const source = request.source ?? "";
  let parserMod;
  try {
    parserMod = loadParser();
  } catch (err) {
    process.stdout.write(
      JSON.stringify(
        failureEnvelope("@babel/parser", "unknown", [
          {
            code: "E7104",
            message: `Failed to load vendored @babel/parser: ${err}`,
            reason: "parser_unavailable",
          },
        ])
      )
    );
    return;
  }

  const parserName = "@babel/parser";
  const parserVer = parserVersion(parserMod);

  try {
    const ast = parserMod.parse(source, {
      sourceType: "unambiguous",
      plugins: pluginsForLanguage(language),
      ranges: true,
      tokens: true,
      comments: true,
      errorRecovery: false,
    });
    const tokens = ast.tokens || [];
    const comments = ast.comments || [];
    delete ast.tokens;
    delete ast.comments;

    process.stdout.write(
      JSON.stringify({
        protocolVersion: PROTOCOL_VERSION,
        parser: { name: parserName, version: parserVer },
        ok: true,
        sourceType: ast.sourceType || "module",
        ast,
        tokens,
        comments,
        features: Array.isArray(request.features) ? request.features : [],
      })
    );
  } catch (err) {
    const loc = err.loc || null;
    process.stdout.write(
      JSON.stringify(
        failureEnvelope(parserName, parserVer, [
          {
            code: "E7102",
            message: String(err.message || err),
            reason: "syntax_error",
            line: loc?.line ?? null,
            column: loc?.column ?? null,
          },
        ])
      )
    );
  }
}

main();
