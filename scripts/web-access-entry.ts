// Re-exports the pi-web-access pieces Jackal's web tools use. Bundled to
// dist/web-access.mjs by scripts/build-web-access.mjs (the package ships raw
// TypeScript, which Node will not load from node_modules).
export { search, SearchProviderError } from "pi-web-access/gemini-search.ts";
export { extractContent } from "pi-web-access/extract.ts";
