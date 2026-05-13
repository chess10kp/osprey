/**
 * Shared position resolver — resolves a symbol name to a file position.
 *
 * Used by position-based tools (hover, definition, references, rename, completions)
 * to allow the LLM to pass a symbol name instead of exact line/character.
 */

import type { DocumentSymbol, SymbolInformation } from "vscode-languageserver-protocol";
import type { LspManager } from "../lsp-manager.js";
import type { TreeSitterManager } from "../tree-sitter/parser-manager.js";
import { extractSymbols, type SymbolInfo } from "../tree-sitter/symbol-extractor.js";
import { getLanguageIdFromPath } from "./language-map.js";
import { readFile } from "node:fs/promises";

export interface ResolvedPosition {
  line: number;       // 1-indexed (tool convention)
  character: number;  // 1-indexed
  symbolName: string;
  source: "lsp" | "tree-sitter";
}

type DocumentSymbolResponse = DocumentSymbol[] | SymbolInformation[] | null;

/**
 * Resolve a symbol name to a position in a file.
 *
 * Priority:
 * 1. LSP document symbols (most accurate)
 * 2. Tree-sitter symbol extraction (fallback)
 *
 * Matching priority:
 * 1. Exact case-sensitive match
 * 2. Case-insensitive exact match
 * 3. Substring match (case-insensitive)
 * 4. Dot-qualified match (e.g. "MyClass.render" matches "render" inside "MyClass")
 */
export async function resolveSymbolPosition(
  filePath: string,
  query: string,
  manager: LspManager,
  treeSitter?: TreeSitterManager | null,
): Promise<ResolvedPosition | null> {
  // Try LSP document symbols first
  const client = await manager.getClientForFile(filePath).catch(() => null);
  if (client) {
    const uri = manager.getFileUri(filePath);
    try {
      const symbols = await client.sendRequest<DocumentSymbolResponse>(
        "textDocument/documentSymbol",
        { textDocument: { uri } }
      );
      if (symbols && symbols.length > 0) {
        const match = findInDocumentSymbols(symbols, query);
        if (match) return match;
      }
    } catch { /* fall through to tree-sitter */ }
  }

  // Try tree-sitter fallback
  if (treeSitter) {
    try {
      const absPath = manager.resolvePath(filePath);
      const content = await readFile(absPath, "utf-8");
      const languageId = getLanguageIdFromPath(filePath);
      if (languageId) {
        const tree = await treeSitter.parse(absPath, content);
        if (tree) {
          const symbols = extractSymbols(tree, languageId);
          const match = findInSymbolInfos(symbols, query);
          if (match) return match;
        }
      }
    } catch { /* fall through */ }
  }

  return null;
}

/**
 * Get top-level symbol names from a file (for error hints).
 */
export async function getSymbolNames(
  filePath: string,
  manager: LspManager,
  treeSitter?: TreeSitterManager | null,
): Promise<string[]> {
  const client = await manager.getClientForFile(filePath).catch(() => null);
  if (client) {
    const uri = manager.getFileUri(filePath);
    try {
      const symbols = await client.sendRequest<DocumentSymbolResponse>(
        "textDocument/documentSymbol",
        { textDocument: { uri } }
      );
      if (symbols && symbols.length > 0) {
        if ("selectionRange" in symbols[0]) {
          return (symbols as DocumentSymbol[]).map(s => s.name);
        }
        return (symbols as SymbolInformation[]).map(s => s.name);
      }
    } catch { /* fall through */ }
  }

  if (treeSitter) {
    try {
      const absPath = manager.resolvePath(filePath);
      const content = await readFile(absPath, "utf-8");
      const languageId = getLanguageIdFromPath(filePath);
      if (languageId) {
        const tree = await treeSitter.parse(absPath, content);
        if (tree) {
          const symbols = extractSymbols(tree, languageId);
          return symbols.map(s => s.name);
        }
      }
    } catch { /* fall through */ }
  }

  return [];
}

// --- LSP DocumentSymbol matching ---

function findInDocumentSymbols(
  symbols: DocumentSymbol[] | SymbolInformation[],
  query: string,
): ResolvedPosition | null {
  if (symbols.length === 0) return null;

  // Check if these are DocumentSymbol (hierarchical) or SymbolInformation (flat)
  if ("selectionRange" in symbols[0]) {
    return findInHierarchicalSymbols(symbols as DocumentSymbol[], query);
  }
  return findInFlatSymbols(symbols as SymbolInformation[], query);
}

interface SymbolCandidate {
  name: string;
  line: number;      // 1-indexed
  character: number; // 1-indexed
  parent?: string;
}

function findInHierarchicalSymbols(
  symbols: DocumentSymbol[],
  query: string,
): ResolvedPosition | null {
  const candidates = flattenDocumentSymbols(symbols);
  return matchCandidates(candidates, query, "lsp");
}

function flattenDocumentSymbols(
  symbols: DocumentSymbol[],
  parent?: string,
): SymbolCandidate[] {
  const result: SymbolCandidate[] = [];
  for (const sym of symbols) {
    result.push({
      name: sym.name,
      line: sym.selectionRange.start.line + 1,
      character: sym.selectionRange.start.character + 1,
      parent,
    });
    if (sym.children && sym.children.length > 0) {
      result.push(...flattenDocumentSymbols(sym.children, sym.name));
    }
  }
  return result;
}

function findInFlatSymbols(
  symbols: SymbolInformation[],
  query: string,
): ResolvedPosition | null {
  const candidates: SymbolCandidate[] = symbols.map(sym => ({
    name: sym.name,
    line: sym.location.range.start.line + 1,
    character: sym.location.range.start.character + 1,
    parent: sym.containerName ?? undefined,
  }));
  return matchCandidates(candidates, query, "lsp");
}

// --- Tree-sitter SymbolInfo matching ---

function findInSymbolInfos(
  symbols: SymbolInfo[],
  query: string,
): ResolvedPosition | null {
  const candidates = flattenSymbolInfos(symbols);
  return matchCandidates(candidates, query, "tree-sitter");
}

function flattenSymbolInfos(
  symbols: SymbolInfo[],
  parent?: string,
): SymbolCandidate[] {
  const result: SymbolCandidate[] = [];
  for (const sym of symbols) {
    result.push({
      name: sym.name,
      line: sym.line,
      character: 1, // tree-sitter symbols don't have column precision for the name
      parent,
    });
    if (sym.children && sym.children.length > 0) {
      result.push(...flattenSymbolInfos(sym.children, sym.name));
    }
  }
  return result;
}

// --- Shared matching logic ---

function matchCandidates(
  candidates: SymbolCandidate[],
  query: string,
  source: "lsp" | "tree-sitter",
): ResolvedPosition | null {
  // Support dot-qualified queries like "MyClass.render"
  const dotIndex = query.lastIndexOf(".");
  let parentFilter: string | undefined;
  let symbolQuery: string;

  if (dotIndex > 0) {
    parentFilter = query.slice(0, dotIndex);
    symbolQuery = query.slice(dotIndex + 1);
  } else {
    symbolQuery = query;
  }

  // If dot-qualified, try to match parent.child first
  if (parentFilter) {
    const qualified = candidates.filter(
      c => c.parent?.toLowerCase() === parentFilter!.toLowerCase()
    );
    const match = matchByPriority(qualified, symbolQuery, source);
    if (match) return match;
  }

  // Fall back to unqualified match across all candidates
  return matchByPriority(candidates, symbolQuery, source);
}

function matchByPriority(
  candidates: SymbolCandidate[],
  query: string,
  source: "lsp" | "tree-sitter",
): ResolvedPosition | null {
  const queryLower = query.toLowerCase();

  // 1. Exact case-sensitive match
  const exact = candidates.find(c => c.name === query);
  if (exact) return { line: exact.line, character: exact.character, symbolName: exact.name, source };

  // 2. Case-insensitive exact match
  const caseInsensitive = candidates.find(c => c.name.toLowerCase() === queryLower);
  if (caseInsensitive) return { line: caseInsensitive.line, character: caseInsensitive.character, symbolName: caseInsensitive.name, source };

  // 3. Substring match (case-insensitive)
  const substring = candidates.find(c => c.name.toLowerCase().includes(queryLower));
  if (substring) return { line: substring.line, character: substring.character, symbolName: substring.name, source };

  return null;
}
